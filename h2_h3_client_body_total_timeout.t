#!/usr/bin/perl

# Tests for request body deadlines on independent HTTP/2 and HTTP/3 streams.

use warnings;
use strict;
use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;
use Test::Nginx::HTTP3;

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 http_v3 proxy rewrite cryptx/)
    ->has_daemon('openssl')->plan(38);

$t->write_file_expand('nginx.conf', <<'EOF');
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    ssl_certificate localhost.crt;
    ssl_certificate_key localhost.key;
    server {
        listen 127.0.0.1:8080;
        listen 127.0.0.1:%%PORT_8980_UDP%% quic;
        http2 on;
        client_body_total_timeout 300ms;
        client_body_timeout 3s;
        location /body { proxy_pass http://127.0.0.1:8081/done; }
        location /stream {
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_pass http://127.0.0.1:8081/read;
        }
        location /post-body {
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
        location /off {
            client_body_total_timeout 0;
            proxy_pass http://127.0.0.1:8081/done;
        }
        location /health { return 200 "OK"; }
    }
    server {
        listen 127.0.0.1:8081;
        location /read { proxy_pass http://127.0.0.1:8081/done; }
        location /done { return 200 "OK"; }
    }
}
EOF

$t->write_file('openssl.conf', <<'EOF');
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();
system('openssl req -x509 -new '
    . "-config $d/openssl.conf -subj /CN=localhost/ "
    . "-out $d/localhost.crt -keyout $d/localhost.key "
    . ">>$d/openssl.out 2>&1") == 0 or die "Cannot create local certificate";

$t->run();

for my $version (2, 3) {
    my $class = "Test::Nginx::HTTP$version";
    my $reset = $version == 2 ? 'RST_STREAM' : 'STOP_SENDING';

    for my $mode ('body', 'stream') {
        my $path = "/$mode/v$version";
        my $s = $class->new();
        my $sid = $s->new_stream({ path => $path, method => 'POST',
            body => 'TEST' });
        is(response_status($s, $sid), 200, "h$version $mode complete body");

        select undef, undef, undef, 0.5;
        $sid = $s->new_stream({ path => '/health' });
        is(response_status($s, $sid), 200,
            "h$version $mode completion cancels timer");

        $sid = $s->new_stream({ path => $path, method => 'POST',
            body_more => 1 });
        send_body($s, $version, $sid, 'TE', 1);
        my $frames = $s->read(all => [{ type => $reset }], wait => 1);
        ok(scalar(grep { $_->{type} eq $reset && $_->{sid} == $sid } @$frames),
            "h$version $mode deadline closes stream");
        like($t->read_file('access.log'),
            qr!POST \Q$path\E HTTP/$version\.0" 408 !,
            "h$version $mode timeout status");

        $sid = $s->new_stream({ path => '/health' });
        is(response_status($s, $sid), 200,
            "h$version $mode connection survives stream timeout");
    }

    for my $mode ('post-body', 'post-stream') {
        my $path = "/$mode/v$version";
        my $s = $class->new();
        my $sid = $s->new_stream({ path => $path, method => 'POST',
            body_more => 1 });
        send_body($s, $version, $sid, 'TE', 1);
        my $frames = $s->read(all => [{ type => $reset }], wait => 1);
        ok(scalar(grep { $_->{type} eq $reset && $_->{sid} == $sid } @$frames),
            "h$version $mode deadline closes stream");
        like($t->read_file('access.log'),
            qr!POST \Q$path\E HTTP/$version\.0"!,
            "h$version $mode timeout post_action request is logged");
        $sid = $s->new_stream({ path => '/health' });
        is(response_status($s, $sid), 200,
            "h$version $mode connection survives post_action");
    }

    my $s = $class->new();
    my $sid = $s->new_stream({ path => '/off', method => 'POST',
        body_more => 1 });
    send_body($s, $version, $sid, 'TE', 1);
    select undef, undef, undef, 0.5;
    send_body($s, $version, $sid, 'ST', 0);
    is(response_status($s, $sid), 200, "h$version zero disables deadline");

    $sid = $s->new_stream({ path => '/body', method => 'POST', body => '' });
    is(response_status($s, $sid), 200, "h$version empty body");
    $sid = $s->new_stream({ path => '/body' });
    is(response_status($s, $sid), 200, "h$version absent body");
}

$t->stop();

sub send_body {
    my ($s, $version, $sid, $body, $more) = @_;
    if ($version == 2) {
        $s->h2_body($body, { body_more => $more });
    } else {
        $s->h3_body($body, $sid, { body_more => $more });
    }
}

sub response_status {
    my ($s, $sid) = @_;
    my $frames = $s->read(all => [{ sid => $sid, fin => 1 }], wait => 2);
    my ($frame) = grep { $_->{type} eq 'HEADERS' && $_->{sid} == $sid } @$frames;
    return $frame ? $frame->{headers}->{':status'} : undef;
}
