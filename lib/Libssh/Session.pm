package Libssh::Session;

use strict;
use warnings;
use Exporter qw(import);
use XSLoader;
use Time::HiRes;

our $VERSION = '0.001';

XSLoader::load('Libssh::Session', $VERSION);

use constant SSH_OK => 0;
use constant SSH_ERROR => -1;
use constant SSH_AGAIN => -2;
use constant SSH_EOF => -127;

use constant SSH_SERVER_ERROR => -1;
use constant SSH_SERVER_NOT_KNOWN => 0;
use constant SSH_SERVER_KNOWN_OK => 1;
use constant SSH_SERVER_KNOWN_CHANGED => 2;
use constant SSH_SERVER_FOUND_OTHER => 3;
use constant SSH_SERVER_FILE_NOT_FOUND => 4;

use constant SSH_PUBLICKEY_HASH_SHA1 => 0;
use constant SSH_PUBLICKEY_HASH_MD5 => 1;

use constant SSH_LOG_NOLOG => 0;
use constant SSH_LOG_WARNING => 1;
use constant SSH_LOG_PROTOCOL => 2;
use constant SSH_LOG_PACKET => 3;
use constant SSH_LOG_FUNCTIONS => 4;
use constant SSH_LOG_RARE => 1; # like WARNING

use constant SSH_AUTH_ERROR => -1;
use constant SSH_AUTH_SUCCESS => 0;
use constant SSH_AUTH_DENIED => 1;
use constant SSH_AUTH_PARTIAL => 2;
use constant SSH_AUTH_INFO => 3;
use constant SSH_AUTH_AGAIN => 4;

use constant SSH_NO_ERROR => 0;
use constant SSH_REQUEST_DENIED => 1;
use constant SSH_FATAL => 2;
use constant SSH_EINTR => 3;

our @EXPORT_OK = qw(
SSH_OK SSH_ERROR SSH_AGAIN SSH_EOF
SSH_LOG_NOLOG SSH_LOG_WARNING SSH_LOG_PROTOCOL SSH_LOG_PACKET SSH_LOG_FUNCTIONS
SSH_AUTH_ERROR SSH_AUTH_SUCCESS SSH_AUTH_DENIED SSH_AUTH_PARTIAL SSH_AUTH_INFO SSH_AUTH_AGAIN
SSH_NO_ERROR SSH_REQUEST_DENIED SSH_FATAL SSH_EINTR
);
our @EXPORT = qw();
our %EXPORT_TAGS = ( 'all' => [ @EXPORT, @EXPORT_OK ] );

my $err;

sub set_err {
    my ($self, %options) = @_;
    
    $err = $options{msg};
    if ($self->{raise_error}) {
        die $err;
    }
    if ($self->{print_error}) {
        warn $err;
    }
}

sub error {
    my ($self, %options) = @_;
    
    if (defined($options{GetErrorSession}) && $options{GetErrorSession}) {
        $err = ssh_get_error_from_session($self->{ssh_session}) if (defined($self->{ssh_session}));
    }
    return $err;
}

sub new {
    my ($class, %options) = @_;
    my $self  = {};
    bless $self, $class;

    $self->{raise_error} = 0;
    $self->{print_error} = 0;
    $self->{ssh_session} = ssh_new();
    if (!defined($self->{ssh_session})) {
        $self->set_err(msg => 'ssh_new failed: cannot init session');
        return undef;
    }
    
    $self->{channels} = {};
    return $self;
}

sub get_session {
    my ($self, %options) = @_;
     
    return $self->{ssh_session};
}

sub check_uint {
    my ($self, %options) = @_;
    
    if (!defined($options{value}) || $options{value} eq '') {
        $self->set_err(msg => sprintf("option '%s' failed: please set a value", $options{type}));
        return 1;
    }
    if ($options{value} !~ /^\d+$/) {
        $self->set_err(msg => sprintf("option '%s' failed: please set a positive number", $options{type}));
        return 1;
    }
    
    return 0;
}

sub option_host {
    my ($self, %options) = @_;
    
    return ssh_options_set_host($self->{ssh_session}, $options{value});
}

sub option_port {
    my ($self, %options) = @_;
    
    return 1 if ($self->check_uint(value => $options{value}, type => 'port'));
    return ssh_options_set_port($self->{ssh_session}, $options{value});
}

sub option_user {
    my ($self, %options) = @_;
    
    return ssh_options_set_user($self->{ssh_session}, $options{value});
}

sub option_timeout {
    my ($self, %options) = @_;
    
    return 1 if ($self->check_uint(value => $options{value}, type => 'timeout'));
    return ssh_options_set_timeout($self->{ssh_session}, $options{value});
}

sub option_stricthostkeycheck {
    my ($self, %options) = @_;
    
    return 1 if ($self->check_uint(value => $options{value}, type => 'StrictHostKeyCheck'));
    return ssh_options_set_stricthostkeycheck($self->{ssh_session}, $options{value});
}

sub option_sshdir {
    my ($self, %options) = @_;
    
    return ssh_options_ssh_dir($self->{ssh_session}, $options{value});
}

sub option_knownhosts {
    my ($self, %options) = @_;
    
    return ssh_options_knownhosts($self->{ssh_session}, $options{value});
}

sub option_identity {
    my ($self, %options) = @_;
    
    return ssh_options_set_identity($self->{ssh_session}, $options{value});
}

sub option_logverbosity {
    my ($self, %options) = @_;
    
    return 1 if ($self->check_uint(value => $options{value}, type => 'LogVerbosity'));
    return ssh_options_set_log_verbosity($self->{ssh_session}, $options{value});
}

sub option_raise_error {
    my ($self, %options) = @_;
    
    $self->{raise_error} = $options{value};
    return 0;
}

sub option_print_error {
    my ($self, %options) = @_;
    
    $self->{print_error} = $options{value};
    return 0;
}

sub options {
    my ($self, %options) = @_;

    foreach my $key (keys %options) {
        my $ret;

        my $func = $self->can("option_" . lc($key));
        if (defined($func)) {
            $ret = $func->($self, value => $options{$key});
        } else {
            $self->set_err(msg => sprintf("option '%s' is not supported", $key));
            return 0;
        }
        if ($ret != 0) {
            # error from libssh (< 0)
            $self->set_err(msg => sprintf("option '%s' failed: %s", $key, ssh_get_error_from_session($self->{ssh_session}))) if ($ret < 0);
            return 0;
        }
    }
    
    return 1;
}

sub get_server_publickey {
    my ($self, %options) = @_;
    
    $self->{pubkey} = undef;
    return ssh_get_publickey($self->{ssh_session});
}

sub get_publickey_hash {
    my ($self, %options) = @_;
    
    my $hash_type = SSH_PUBLICKEY_HASH_SHA1;
    if (defined($options{Type}) && 
        ($options{Type} == SSH_PUBLICKEY_HASH_SHA1 || $options{Type} == SSH_PUBLICKEY_HASH_MD5)) {
        $hash_type = $options{Type};
    }
    
    return ssh_get_publickey_hash($self->{pubkey}, $hash_type);
}

sub get_hexa {
    my ($self, %options) = @_;

    return ssh_get_hexa($options{value});
}

sub is_server_known {
    my ($self, %options) = @_;
    
    return ssh_is_server_known($self->{ssh_session});
}

sub write_knownhost {
    my ($self, %options) = @_;
    
    return ssh_write_knownhost($self->{ssh_session});
}

sub verify_knownhost {
    my ($self, %options) = @_;
    
    my $ret = $self->is_server_known();
    
    $self->{pubkey} = $self->get_server_publickey();
    if (!defined($self->{pubkey})) {
        $self->set_err(msg => sprintf("get server pubkey failed: %s", ssh_get_error_from_session($self->{ssh_session})));
        return SSH_ERROR;
    }
    
    my $pubkey_hash = $self->get_publickey_hash();
    ssh_key_free($self->{pubkey});
    if (!defined($pubkey_hash)) {
        $self->set_err(msg => sprintf("get server pubkey hash failed: %s", ssh_get_error_from_session($self->{ssh_session})));
        return SSH_ERROR;
    }
        
    if ($ret == SSH_SERVER_KNOWN_OK) {
        return SSH_OK;
    } elsif ($ret == SSH_SERVER_ERROR) {
        $self->set_err(msg => sprintf("knownhost failed: %s", ssh_get_error_from_session($self->{ssh_session})));
    } elsif ($ret == SSH_SERVER_FILE_NOT_FOUND || $ret == SSH_SERVER_NOT_KNOWN) {
        if ($self->write_knownhost() == SSH_OK) {
            return SSH_OK;
        }
        $self->set_err(msg => sprintf("knownhost write failed: %s", get_strerror()));
    } elsif ($ret == SSH_SERVER_KNOWN_CHANGED) {
        return SSH_OK if (defined($options{SkipKeyProblem}) && $options{SkipKeyProblem});
        $self->set_err(msg => sprintf("knownhost failed: Host key for server changed: it is now: %s", 
                                      $self->get_hexa(value => $pubkey_hash)));
    } elsif ($ret == SSH_SERVER_FOUND_OTHER) {
        return SSH_OK if (defined($options{SkipKeyProblem}) && $options{SkipKeyProblem});
        $self->set_err(msg => sprintf("knownhost failed: The host key for this server was not found but an other type of key exists."));
    }

    return SSH_ERROR;
}

sub connect {
    my ($self, %options) = @_;
    my $skip_key_problem = defined($options{SkipKeyProblem}) ? $options{SkipKeyProblem} : 1;

    my $ret = ssh_connect($self->{ssh_session});
    if ($ret != SSH_OK) {
        $self->set_err(msg => sprintf("connect failed: %s", ssh_get_error_from_session($self->{ssh_session})));
        return $ret;
    }
    if (!(defined($options{connect_only}) && $options{connect_only} == 1)) {
        if (($ret = $self->verify_knownhost(SkipKeyProblem => $skip_key_problem)) != SSH_OK) {
            return $ret;
        }
    }
    
    return SSH_OK;
}

sub disconnect {
    my ($self) = @_;
    
    if (ssh_is_connected($self->{ssh_session}) == 1) {
        ssh_disconnect($self->{ssh_session});
    }
}

sub auth_password {
    my ($self, %options) = @_;

    my $ret = ssh_userauth_password($self->{ssh_session}, $options{password});
    if ($ret == SSH_AUTH_ERROR) {
        $self->set_err(msg => sprintf("authentification failed: %s", ssh_get_error_from_session($self->{ssh_session})));
    }

    return $ret;
}

sub auth_publickey_auto {
    my ($self, %options) = @_;
    my $pass_defined = 1;
    
    if (!defined($options{passphrase})) {
        $options{passphrase} = '';
        $pass_defined = 0;
    }
    my $ret = ssh_userauth_publickey_auto($self->{ssh_session}, $options{passphrase}, $pass_defined);
    if ($ret == SSH_AUTH_ERROR) {
        $self->set_err(msg => sprintf("authentification failed: %s", ssh_get_error_from_session($self->{ssh_session})));
    }

    return $ret;
}

sub auth_none {
    my ($self, %options) = @_;

    my $ret = ssh_userauth_none($self->{ssh_session});
    if ($ret == SSH_AUTH_ERROR) {
        $self->set_err(msg => sprintf("authentification failed: %s", ssh_get_error_from_session($self->{ssh_session})));
    }

    return $ret;
}

sub get_fd {
    my ($self, %options) = @_;
    
    return ssh_get_fd($self->{ssh_session});
}

sub get_issue_banner {
    my ($self, %options) = @_;
    
    return ssh_get_issue_banner($self->{ssh_session});
}

#
# Channel functions
#

sub add_command {
    my ($self, %options) = @_;
    my $timeout = (defined($options{timeout}) && int($options{timeout}) > 0) ? 
        $options{timeout} : 300;
    my $timeout_nodata = (defined($options{timeout_nodata}) && int($options{timeout_nodata}) > 0) ? 
        $options{timeout_nodata} : 120;
    
    my $channel_id = $self->open_channel();
    if ($channel_id !~ /^\d+\:\d+$/) {
        $options{command}->{callback}->(exit => SSH_ERROR, error_msg => 'cannot init channel', session => $self);
        return undef;
    }

    $self->{slots}->{$channel_id} = $options{command};
    $self->{slots}->{$channel_id}->{timeout_counter} = $timeout;
    $self->{slots}->{$channel_id}->{timeout_nodata_counter} = $timeout_nodata;
    $self->{slots}->{$channel_id}->{stdout} = '';
    $self->{slots}->{$channel_id}->{stderr} = '';
    $self->{slots}->{$channel_id}->{read} = 0;
    
    $self->channel_request_exec(channel => ${$self->{channels}->{$channel_id}},
                                cmd => $options{command}->{cmd});
}

sub execute_read_channel {
    my ($self, %options) = @_;
    
    my $channel = ${$self->{channels}->{$options{channel_id}}};
    my $channel_id = $options{channel_id};

    # read stdout
    while (1) {
        my $result = ssh_channel_read($channel, 4092, 0, 1);
        if (defined($result->{message})) {
            $self->{slots}->{$channel_id}->{stdout} .= $result->{message};
        }

        last if ($result->{code} != 4092);
    }
    
    # read stderr
    while (1) {
        my $result = ssh_channel_read($channel, 4092, 1, 1);
        if (defined($result->{message})) {
            $self->{slots}->{$channel_id}->{stderr} .= $result->{message};
        }
        
        last if ($result->{code} != 4092);
    }
    
    if (ssh_channel_is_eof($channel) != 0) {
        $self->{slots}->{$channel_id}->{exit_code} = ssh_channel_get_exit_status($channel);
        $self->close_channel(channel_id => $channel_id);
        $self->{slots}->{$channel_id}->{callback}->(
            exit => SSH_OK,
            session => $self,
            exit_code => $self->{slots}->{$channel_id}->{exit_code},
            userdata => $self->{slots}->{$channel_id}->{userdata},
            stdout => $self->{slots}->{$channel_id}->{stdout},
            stderr => $self->{slots}->{$channel_id}->{stderr},
        );
        delete $self->{slots}->{$channel_id};
    } else {
        $self->{slots}->{$channel_id}->{read} = 1;
    }
}

sub execute {
    my ($self, %options) = @_;
    my $parallel = (defined($options{parallel}) && int($options{parallel}) > 0) ? 
        $options{parallel} : 4;
    
    $self->{slots} = {};
    $self->{channels_array} = [];
    while (1) {
        while (scalar(keys %{$self->{slots}}) < $parallel && scalar(@{$options{commands}}) > 0) {
            $self->add_command(command => shift(@{$options{commands}}), %options);
        }
        
        last if (scalar(keys %{$self->{slots}}) == 0);
        
        my @chanels_array = ();
        foreach (keys %{$self->{slots}}) {
            $self->{slots}->{$_}->{read} = 0;
            push @chanels_array, ${$self->{channels}->{$_}};
        }
        
        my $now = Time::HiRes::time();
        my $ret = ssh_channel_select_read(\@chanels_array, 5);
        if ($ret->{code} == SSH_OK) {
            foreach (@{$ret->{channel_ids}}) {
                my ($session_id, $channel_id) = split /\./;
                
                $self->execute_read_channel(channel_id => $channel_id);
            }
        }
        my $now2 = Time::HiRes::time();
        
        # check timeout
        my $seconds = ($now2 - $now) / 1000;
        foreach (keys %{$self->{slots}}) {
            $self->{slots}->{$_}->{timeout_counter} -= $seconds;
            if ($self->{slots}->{$_}->{read} == 0) {
                $self->{slots}->{$_}->{timeout_nodata_counter} -= $seconds;
            }
            
            if ($self->{slots}->{$_}->{timeout_counter} <= 0 || 
                $self->{slots}->{$_}->{timeout_nodata_counter} <= 0) {
                $self->close_channel(channel_id => $_);
                $self->{slots}->{$_}->{callback}->(
                    exit => SSH_AGAIN,
                    session => $self,
                    exit_code => undef,
                    userdata => $self->{slots}->{$_}->{userdata},
                    stdout => $self->{slots}->{$_}->{stdout},
                    stderr => $self->{slots}->{$_}->{stderr},
                );
                delete $self->{slots}->{$_};
            }
        }        
    }
}

sub open_channel {
    my ($self, %options) = @_;
    
    my $channel = $self->channel_new();
    if (!defined($channel)) {
        return SSH_ERROR;
    }
    if ($self->channel_open_session(channel => $channel) != SSH_OK) {
        $self->channel_free(channel => $channel);
        return SSH_ERROR;
    }
    
    my $channel_id = ssh_channel_get_id($channel);
    $self->{channels}->{$channel_id} = \$channel;

    return $channel_id;
}

sub get_channel {
    my ($self, %options) = @_;
    
    if (!defined($options{channel_id}) || !defined($self->{channels}->{$options{channel_id}})) {
        return undef;
    }
    
    return $self->{channels}->{$options{channel_id}};
}

sub close_channel {
    my ($self, %options) = @_;
    
    if (!defined($options{channel_id}) || !defined($self->{channels}->{$options{channel_id}})) {
        return undef;
    }
    $self->channel_close(channel => ${$self->{channels}->{$options{channel_id}}});
    $self->channel_send_eof(channel => ${$self->{channels}->{$options{channel_id}}});
    $self->channel_free(channel => ${$self->{channels}->{$options{channel_id}}});
    
    delete $self->{channels}->{$options{channel_id}};
}

sub is_closed_channel {
    my ($self, %options) = @_;
    
    if (!defined($options{channel_id}) || !defined($self->{channels}->{$options{channel_id}})) {
        return undef;
    }
    
    return $self->channel_close(channel => ${$self->{channels}->{$options{channel_id}}});;
}

sub channel_new {
    my ($self, %options) = @_;
    
    return ssh_channel_new($self->{ssh_session});
}

sub channel_open_session {
    my ($self, %options) = @_;
    
    return ssh_channel_open_session($options{channel});
}

sub channel_request_exec {
    my ($self, %options) = @_;
    
    return ssh_channel_request_exec($options{channel}, $options{cmd});
}

sub channel_close {
    my ($self, %options) = @_;
    
    return ssh_channel_close($options{channel});
}

sub channel_free {
    my ($self, %options) = @_;
    
    return ssh_channel_free($options{channel});
}

sub channel_send_eof {
    my ($self, %options) = @_;
    
    return ssh_channel_send_eof($options{channel});
}

sub channel_is_eof {
    my ($self, %options) = @_;
    
    return ssh_channel_is_eof($options{channel});
}

sub channel_is_closed {
    my ($self, %options) = @_;
    
    return ssh_channel_is_closed($options{channel});
}

sub DESTROY {
    my ($self) = @_;

    if (defined($self->{ssh_session})) {
        foreach my $channel_id (keys %{$self->{channels}}) {
            $self->close_channel(channel_id => $channel_id);
        }
    
        $self->disconnect();
        ssh_free($self->{ssh_session});
    }
}

1;

__END__

=head1 NAME

Libssh::Session - Support for the SSH protocol via libssh.

=head1 SYNOPSIS

  !/usr/bin/perl

  use strict;
  use warnings;
  use Libssh::Session qw(:all);

  my $session = Libssh::Session->new();
  if (!$session->options(host => "127.0.0.1", port => 22)) {
    print $session->error() . "\n";
    exit(1);
  }

  if ($session->connect() != SSH_OK) {
    print $session->error() . "\n";
    exit(1);
  }
  
  if ($session->auth_password(password => "password") != SSH_AUTH_SUCCESS) {
    printf("auth issue: %s\n", $session->error(GetErrorSession => 1));
    exit(1);
  }

  print "== authentification succeeded\n";

  $session->execute(commands => [ 
                    { cmd => 'ls -l', callback => \&my_callback, userdata => 'cmd 1'},
                    { cmd => 'ls wanterrormsg', callback => \&my_callback, userdata => 'cmd 2 error'},
                  ],
                  timeout => 60, timeout_nodata => 30, parallel => 4);
  exit(0);

=head1 DESCRIPTION

C<Libssh::Session> is a perl interface to the libssh (L<http://www.libssh.org>)
library. It doesn't support all the library. It's working in progress.

=head1 METHODS

=over 4

=item new

Create new Session object:

    my $session = Libssh::Session->new();

=item error ( )

Returns the last error message; returns undef if no error.

=item get_server_publickey ( )

Returns the server public key. if an error occured, undef is returned.

B<Warning>: should be used if you know whare are you doing!

=item get_publickey_hash ([ OPTIONS ])

Get a hash of the public key. if an error occured, undef is returned.

C<OPTIONS> are passed in a hash like fashion, using key and value pairs. Possible options are:

B<Type> - Hash type to used. Default: SSH_PUBLICKEY_HASH_SHA1. Can be: SSH_PUBLICKEY_HASH_MD5.

=back

=cut