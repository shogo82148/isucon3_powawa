package Isucon3::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use DBIx::Sunny;
use JSON qw/ decode_json /;
use Digest::SHA qw/ sha256_hex /;
use DBIx::Sunny;
use File::Temp qw/ tempfile /;
use IO::Handle;
use Encode;
use Time::Piece;
use Redis::Fast;
use Data::MessagePack;
use Text::Markdown::Discount qw/markdown/;
use Encode;

sub load_config {
    my $self = shift;
    $self->{_config} ||= do {
        my $env = $ENV{ISUCON_ENV} || 'local';
        open(my $fh, '<', $self->root_dir . "/../config/${env}.json") or die $!;
        my $json = do { local $/; <$fh> };
        close($fh);
        decode_json($json);
    };
}

sub dbh {
    my ($self) = @_;
    $self->{_dbh} ||= do {
        my $dbconf = $self->load_config->{database};
        DBIx::Sunny->connect(
            "dbi:mysql:database=${$dbconf}{dbname};host=${$dbconf}{host};port=${$dbconf}{port}", $dbconf->{username}, $dbconf->{password}, {
                RaiseError => 1,
                PrintError => 0,
                AutoInactiveDestroy => 1,
                mysql_enable_utf8   => 1,
                mysql_auto_reconnect => 1,
            },
        );
    };
}

sub redis {
    my ($self) = @_;
    $self->{_redis} ||= do {
        Redis::Fast->new( encoding  => undef, );
    };
}

sub mp {
    my ($self) = @_;
    $self->{_mp} ||= do {
        Data::MessagePack->new();
    };
}

sub public_count {
    my ($self) = @_;
    return $self->redis->get('memo:public:count');
}

filter 'session' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        my $sid = $c->req->env->{"psgix.session.options"}->{id};
        $c->stash->{session_id} = $sid;
        $c->stash->{session}    = $c->req->env->{"psgix.session"};
        $app->($self, $c);
    };
};

filter 'get_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;

        my $user_id = $c->req->env->{"psgix.session"}->{user_id};
        my $user_cache;
        $user_cache = $self->redis->get('user:' . $user_id) if $user_id;
        my $user;
        if($user_cache) {
            $user = $self->mp->unpack($user_cache);
        } else {
            $user = $self->dbh->select_row(
                'SELECT * FROM users WHERE id=?',
                $user_id,
            );
            $self->redis->set('user:' . $user_id, $self->mp->pack($user)) if $user;
        }
        $c->stash->{user} = $user;
        $c->res->header('Cache-Control', 'private') if $user;
        $app->($self, $c);
    }
};

filter 'require_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        unless ( $c->stash->{user} ) {
            return $c->redirect('/');
        }
        $app->($self, $c);
    };
};

filter 'anti_csrf' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        my $sid   = $c->req->param('sid');
        my $token = $c->req->env->{"psgix.session"}->{token};
        if ( $sid ne $token ) {
            return $c->halt(400);
        }
        $app->($self, $c);
    };
};

sub get_recent {
    my ($self, $c, $page) = @_;
    my $r = $self->redis;
    my $mp = $self->mp;

    my $memos = $r->hget('recent', $page);
    if($memos) {
        return decode_utf8 $memos;
    } else {
        my @list_memos = map {$mp->unpack($_)} $r->sort('memo:public', 'BY', 'nosort', 'GET', 'memo:*', 'LIMIT', $page * 100, 100);
        return unless(@list_memos);
        $memos = $c->tx->render('memos.tx', {
            c => $c,
            stash => $c,
            memos => \@list_memos,
        });
        $r->hset('recent', $page, encode_utf8 $memos);
        return $memos;
    }
}

get '/' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    my $r = $self->redis;
    my $mp = $self->mp;

    my $total = $self->public_count;
    my $memos = $self->get_recent($c, 0);
    $c->render('index.tx', {
        memos => $memos,
        page  => 0,
        total => $total,
    });
};

get '/recent/:page' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    my $page  = int $c->args->{page};
    my $total = $self->public_count;

    my $r = $self->redis;
    my $mp = $self->mp;
    my $memos = $self->get_recent($c, $page);
    unless($memos) {
        return $c->halt(404);
    }

    $c->render('index.tx', {
        memos => $memos,
        page  => $page,
        total => $total,
    });
};

get '/signin' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    $c->render('signin.tx', {});
};

post '/signout' => [qw(session get_user require_user anti_csrf)] => sub {
    my ($self, $c) = @_;
    $c->req->env->{"psgix.session.options"}->{change_id} = 1;
    delete $c->req->env->{"psgix.session"}->{user_id};
    $c->redirect('/');
};

post '/signup' => [qw(session anti_csrf)] => sub {
    my ($self, $c) = @_;

    my $username = $c->req->param("username");
    my $password = $c->req->param("password");
    my $user = $self->dbh->select_row(
        'SELECT id, username, password, salt FROM users WHERE username=?',
        $username,
    );
    if ($user) {
        $c->halt(400);
    }
    else {
        my $salt = substr( sha256_hex( time() . $username ), 0, 8 );
        my $password_hash = sha256_hex( $salt, $password );
        $self->dbh->query(
            'INSERT INTO users (username, password, salt) VALUES (?, ?, ?)',
            $username, $password_hash, $salt,
        );
        my $user_id = $self->dbh->last_insert_id;
        $c->req->env->{"psgix.session"}->{user_id} = $user_id;
        $c->redirect('/mypage');
    }
};

post '/signin' => [qw(session)] => sub {
    my ($self, $c) = @_;

    my $username = $c->req->param("username");
    my $password = $c->req->param("password");
    my $user = $self->dbh->select_row(
        'SELECT id, username, password, salt FROM users WHERE username=?',
        $username,
    );
    if ( $user && $user->{password} eq sha256_hex($user->{salt} . $password) ) {
        $c->req->env->{"psgix.session.options"}->{change_id} = 1;
        my $session = $c->req->env->{"psgix.session"};
        $session->{user_id} = $user->{id};
        $session->{token}   = sha256_hex(rand());
        $self->dbh->query(
            'UPDATE users SET last_access=now() WHERE id=?',
            $user->{id},
        );
        return $c->redirect('/mypage');
    }
    else {
        $c->render('signin.tx', {});
    }
};

get '/mypage' => [qw(session get_user require_user)] => sub {
    my ($self, $c) = @_;

    my $memos = $self->dbh->select_all(
        'SELECT id, content, is_private, created_at, updated_at FROM memos WHERE user=? ORDER BY id DESC',
        $c->stash->{user}->{id},
    );
    $c->render('mypage.tx', { memos => $memos });
};

post '/memo' => [qw(session get_user require_user anti_csrf)] => sub {
    my ($self, $c) = @_;
    my $is_private = scalar($c->req->param('is_private')) ? 1 : 0;
    $self->redis->incr('memo:public:count') unless $is_private;
    my $memo_id = $self->redis->incr('memo:count');
    my $redis = $self->redis;

    $self->dbh->query(
        'INSERT INTO memos (id, user, content, is_private, created_at) VALUES (?, ?, ?, ?, now())',
        $memo_id,
        $c->stash->{user}->{id},
        scalar $c->req->param('content'),
        $is_private,
    );

    my $memo = $self->dbh->select_row(
        'SELECT id, user, content, is_private, created_at, updated_at FROM memos WHERE id=?',
        $memo_id,
    );
    $memo->{username} = $c->stash->{user}->{username},
    $redis->set(
        sprintf('memo:%d', $memo_id),
        $self->mp->pack($memo),
        sub {},
    );
    unless($memo->{is_private}) {
        $redis->lpush(
            'memo:public',
            $memo->{id},
            sub {},
        );
        $redis->del('recent', sub{});
    }
    $redis->set(
        sprintf('memo:%d:content', $memo_id),
        encode_utf8 markdown($memo->{content}),
        sub {},
    );
    $redis->wait_all_responses;
    $c->redirect('/memo/' . $memo_id);
};

get '/memo/:id' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;

    my $user = $c->stash->{user};
    my $redis = $self->redis;
    my ($memo, $content);
    $redis->get(
        sprintf('memo:%d', $c->args->{id}),
        sub {
            $memo = shift;
        },
    );
    $redis->get(
        sprintf('memo:%d:content', $c->args->{id}),
        sub {
            $content = decode_utf8 shift;
        },
    );
    $redis->wait_all_responses;

    $memo = $self->mp->unpack($memo) if $memo;
    unless ($memo) {
        $c->halt(404);
    }
    if ($memo->{is_private}) {
        if ( !$user || $user->{id} != $memo->{user} ) {
            $c->halt(404);
        }
    }
    $memo->{content_html} = $content;

    my $cond;
    if ($user && $user->{id} == $memo->{user}) {
        $cond = "";
    }
    else {
        $cond = "AND is_private=0";
    }

    my $memos = $self->dbh->select_all(
        "SELECT * FROM memos WHERE user=? $cond ORDER BY id",
        $memo->{user},
    );
    my ($newer, $older);
    for my $i ( 0 .. scalar @$memos - 1 ) {
        if ( $memos->[$i]->{id} eq $memo->{id} ) {
            $older = $memos->[ $i - 1 ] if $i > 0;
            $newer = $memos->[ $i + 1 ] if $i < @$memos;
        }
    }

    $c->render('memo.tx', {
        memo  => $memo,
        older => $older,
        newer => $newer,
    });
};

1;
