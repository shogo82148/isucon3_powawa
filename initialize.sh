#!/bin/bash
set -u
set -e
umask 0077
export PATH='/bin:/usr/bin'
export LANG='C'

mysql -B -N -uroot -proot -e'show indexes from memos' isucon | grep i_memos_1
[[ $? = 0 ]] && mysql -uroot -proot -e'drop index i_memos_1 on memos' isucon
mysql -B -N -uroot -proot -e'show indexes from memos' isucon | grep i_memos_2
[[ $? = 0 ]] && mysql -uroot -proot -e'drop index i_memos_2 on memos' isucon
mysql -B -N -uroot -proot -e'show indexes from memos' isucon | grep i_memos_3
[[ $? = 0 ]] && mysql -uroot -proot -e'drop index i_memos_3 on memos' isucon

mysql -uroot -proot isucon << _EOT_
create index i_memos_1 on memos (is_private, created_at);
create index i_memos_2 on memos (user, created_at);
create index i_memos_3 on memos (user, is_private, created_at);
_EOT_
