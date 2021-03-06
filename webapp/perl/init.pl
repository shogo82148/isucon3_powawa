#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use 5.018;

use FindBin;
use lib "$FindBin::Bin/extlib/lib/perl5";
use lib "$FindBin::Bin/lib";

use Isucon3::Web;
use Text::Markdown::Discount qw/markdown/;
use Encode;

my $web = Isucon3::Web->new;
my $dbh = $web->dbh;
my $redis = $web->redis;
my $mp = $web->mp;

$redis->flushdb;

$redis->set(
    'memo:count',
    $dbh->select_one(
        'SELECT count(*) FROM memos'
    ),
    sub {},
);

$redis->set(
    'memo:public:count',
    $dbh->select_one(
        'SELECT count(*) FROM memos WHERE is_private=0'
    ),
    sub {},
);

my $memos = $dbh->select_all(
    'SELECT * FROM memos',
);
for my $memo (@$memos) {
    $memo->{username} = $dbh->select_one(
        'SELECT username FROM users WHERE id=?',
        $memo->{user},
    );
    $redis->set(
        sprintf('memo:%d', $memo->{id}),
        $mp->pack($memo),
        sub {},
    );
    $redis->lpush(
        'memo:public',
        $memo->{id},
        sub {},
    ) unless $memo->{is_private};

    $redis->set(
        sprintf('memo:%d:content', $memo->{id}),
        encode_utf8 markdown($memo->{content}),
        sub {},
    );
}

$redis->wait_all_responses;

$dbh->do("alter table memos add index user_idx (user ASC)");
