#!/usr/bin/perl

# Tests for total request body duration and timer cleanup.

use warnings;
use strict;

use Test::More;
use Socket qw/ CRLF /;
use Time::HiRes qw/ time /;
use IO::Socket::INET;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx qw/ http_start http_end /;

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy rewrite mirror/)->plan(24);

$t->write_file_expand('nginx.conf', <<'EOF');
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    client_body_total_timeout 300ms;
    client_body_timeout 3s;

    server {
        listen 127.0.0.1:8080;
        server_name localhost;
        add_header X-Body $request_body;

        location / {
            proxy_pass http://127.0.0.1:8081/done;
        }
        location /off {
            client_body_total_timeout 0;
            proxy_pass http://127.0.0.1:8081/done;
        }
        location /long {
            client_body_total_timeout 2s;
            proxy_pass http://127.0.0.1:8081/done;
        }
        location /stream {
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_pass http://127.0.0.1:8081/read;
        }
        location /post-buffered {
            post_action /post-done;
            proxy_pass http://127.0.0.1:8081/done;
        }
        location /post-stream {
            post_action /post-done;
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_pass http://127.0.0.1:8081/read;
        }
        location = /post-done { return 204; }
        location /delayed {
            proxy_pass http://127.0.0.1:8082;
        }
        location /mirrored {
            mirror /mirror;
            proxy_pass http://127.0.0.1:8082;
        }
        location = /mirror { return 204; }
        location /redirect {
            rewrite ^ /delayed last;
        }
        location /limited {
            client_max_body_size 3;
            error_page 413 = /delayed;
            proxy_pass http://127.0.0.1:8081/done;
        }
        location /idle {
            client_body_timeout 100ms;
            client_body_total_timeout 2s;
            proxy_pass http://127.0.0.1:8081/done;
        }
        location = /health { return 200 "OK"; }
    }
    server {
        listen 127.0.0.1:8081;
        client_body_total_timeout 0;
        location /read { proxy_pass http://127.0.0.1:8081/done; }
        location /done { return 200 "OK"; }
    }
    server {
        listen 127.0.0.1:8083;
        client_body_total_timeout 2s;
        location / { proxy_pass http://127.0.0.1:8081/done; }
    }
}
EOF

$t->run_daemon(\&delayed_backend);
$t->waitforsocket('127.0.0.1:' . port(8082));
$t->run();

like(http(request('/', 'TEST')), qr/X-Body: TEST/, 'preread body');
like(http(request('/', 'TE'), sleep => 0.05, body => 'ST'),
    qr/X-Body: TEST/, 'body completed before deadline');
like(http(request('/off', 'TE'), sleep => 0.5, body => 'ST'),
    qr/ 200 /, 'zero disables inherited deadline');
like(http(request('/long', 'TE'), sleep => 0.5, body => 'ST'),
    qr/ 200 /, 'location overrides deadline');
like(http(request('/', 'TE'), sleep => 0.5, body => 'ST',
    PeerAddr => '127.0.0.1:' . port(8083)), qr/ 200 /,
    'server overrides http deadline');

for my $path ('/fixed', '/stream') {
    my $start = time();
    my $s = http_start(request($path, 'TE'));
    http_end($s);
    cmp_ok(time() - $start, '<', 1.5, "$path total deadline precedes idle");
    like($t->read_file('access.log'), qr!POST \Q$path\E HTTP/1.1" 408 !,
        "$path terminates with timeout status");
}

for my $path ('/post-buffered', '/post-stream') {
    my $s = http_start(request($path, 'TE'));
    http_end($s);
    like(wait_for_log($t, qr!POST \Q$path\E HTTP/1.1"!),
        qr!POST \Q$path\E HTTP/1.1"!,
        "$path request is logged after timeout post_action");
}

like(http(chunked('/', "4\r\nTEST\r\n0\r\n\r\n")),
    qr/X-Body: TEST/, 'complete chunked body');
my $s = http_start(chunked('/chunked', "4\r\nTE"));
http_end($s);
like($t->read_file('access.log'), qr!POST /chunked HTTP/1.1" 408 !,
    'chunked body deadline');

like(http(request('/delayed', 'TEST')), qr/ 200 /,
    'body completion cancels timer before delayed response');
like(http(request('/mirrored', 'TEST')), qr/ 200 /,
    'body reused by subrequest and proxy does not restart timer');
like(http(request('/redirect', 'TEST')), qr/ 200 /,
    'internal redirect before body reading');
like(http(chunked('/limited', "4\r\nTEST\r\n0\r\n\r\n")), qr/ 200 /,
    'body read error cancels timer before delayed error page');

$s = http_start(request('/aborted', 'TE'));
select undef, undef, undef, 0.05;
close $s;
select undef, undef, undef, 0.5;
like(http_get('/health'), qr/ 200 /, 'worker serves after early close');
unlike($t->read_file('error.log'),
    qr/client request body timed out[^\n]*POST \/aborted /,
    'early close removes pending deadline');

my $start = time();
$s = http_start(request('/idle', 'TE'));
http_end($s);
cmp_ok(time() - $start, '<', 1.5, 'inactivity timeout still takes precedence');
like($t->read_file('access.log'), qr!POST /idle HTTP/1.1" 408 !,
    'inactivity timeout status');
unlike($t->read_file('error.log'),
    qr/client request body timed out[^\n]*POST \/idle /,
    'inactivity expiry is distinct from total deadline');

like(http(request('/delayed', '', 0)), qr/ 200 /,
    'empty body does not time out during response');
like(http_get('/delayed'), qr/ 200 /,
    'absent body does not time out during response');

$t->stop();

sub wait_for_log {
    my ($test, $pattern) = @_;
    my $deadline = time() + 2;
    my $log;

    while (time() < $deadline) {
        $log = $test->read_file('access.log');
        return $log if $log =~ $pattern;
        select undef, undef, undef, 0.05;
    }

    return $log;
}

sub request {
    my ($path, $body, $length) = @_;
    $length = 4 unless defined $length;
    return "POST $path HTTP/1.1" . CRLF . 'Host: localhost' . CRLF
        . 'Connection: close' . CRLF . "Content-Length: $length" . CRLF
        . CRLF . $body;
}

sub chunked {
    my ($path, $body) = @_;
    return "POST $path HTTP/1.1" . CRLF . 'Host: localhost' . CRLF
        . 'Connection: close' . CRLF . 'Transfer-Encoding: chunked' . CRLF
        . CRLF . $body;
}

sub delayed_backend {
    my $server = IO::Socket::INET->new(
        Proto => 'tcp', LocalAddr => '127.0.0.1:' . port(8082),
        Listen => 5, Reuse => 1
    ) or die "Cannot create local backend: $!";

    while (my $client = $server->accept()) {
        $client->autoflush(1);
        my $headers = '';
        while (my $line = <$client>) {
            $headers .= $line;
            last if $line eq CRLF;
        }
        if ($headers ne '') {
            my ($length) = $headers =~ /Content-Length: (\d+)/i;
            if ($length) {
                my $body = '';
                read($client, $body, $length);
            }
            select undef, undef, undef, 0.5;
            print $client "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK";
        }
        close $client;
    }
}
