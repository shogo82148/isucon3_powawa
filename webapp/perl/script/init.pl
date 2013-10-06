#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use 5.018;

use FindBin::libs;
use Isucon3::Web;

my $web = Isucon3::Web->new;
my $dbh = $web->dbh;
my $redis = $web->redis;

$redis->set(
    'memo:count',
    $self->dbh->select_one(
        'SELECT count(*) FROM memos WHERE is_private=0'
    ),
);

my $memos = $self->dbh->select_all(
    'SELECT * FROM memos WHERE is_private=0 ORDER BY created_at DESC, id DESC LIMIT 100',
);
for my $memo (@$memos) {
    $memo->{username} = $self->dbh->select_one(
        'SELECT username FROM users WHERE id=?',
        $memo->{user},
    );
    $redis->hmset(
        sprintf('memo:%d', $memo->{id}),
        %$memo,
    );
}
