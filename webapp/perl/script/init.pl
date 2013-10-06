use strict;
use DBI;
use Data::Dumper;

my $dsn = "DBI:mysql:database=isucon;host=localhost;port=3306";
my $dbh = DBI->connect($dsn, "isucon", "", { AutoCommit => 0});


$dbh->do("alter table memos add column username varchar(255)");

my $sth = $dbh->prepare("select * from users;");
$sth->execute;
my $users = $sth->fetchall_hashref('id');

my $insert_sth = $dbh->prepare("update memos set username=? where id=?");
my $memo_sth = $dbh->prepare("select id, user from memos");
$memo_sth->execute;
my $i = 0;
while (my $row = $memo_sth->fetchrow_hashref) {
    my $user_id = $row->{user};
    my $username = $users->{$user_id}->{username};
    
    $insert_sth->execute($username, $row->{id});
    #print Dumper $row;
}
#print Dumper $users;
$dbh->do("alter table memos add index user_idx (user ASC)");

$dbh->commit;

$dbh->disconnect;

