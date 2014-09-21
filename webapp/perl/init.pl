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

eval { $dbh->do("ALTER TABLE memos ADD title VARCHAR(255)"); };
eval { $dbh->do("ALTER TABLE memos ADD content_html TEXT"); };

my $memos = $dbh->select_all(
    'SELECT * FROM memos',
    );
for my $memo (@$memos) {
    my ($title) = split /\r?\n/, $memo->{content};
    my $content_html = markdown($memo->{content});
    $dbh->query('UPDATE memos SET title = ?, content_html = ? WHERE id = ?',
	$title, $content_html, $memo->{id});
}
