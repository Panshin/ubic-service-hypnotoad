package Ubic::Service::Hypnotoad;
# ABSTRACT: Ubic service module for Mojolicious Hypnotoad

use strict;
use warnings;

use parent qw(Ubic::Service::Skeleton);

use Ubic::Result qw(result);
use File::Basename;
use Time::HiRes qw(time);
use Capture::Tiny qw(:all);
use File::Spec::Functions qw(catfile file_name_is_absolute);
use Carp qw(croak carp);

=head1 SYNOPSIS

    use Ubic::Service::Hypnotoad;
    return Ubic::Service::Hypnotoad->new({
        bin => '/usr/bin/hypnotoad', # or 'carton exec hypnotoad', or ['carton', 'exec', 'hypnotoad'], optional, defaults to 'hypnotoad'
        app => '/home/www/mysite.app',
        pid_file => '/var/log/mysite.pid', # optional, defaults to a hypnotoad.pid file lying next to "app"
        cwd => '/path/to/app/', # optional, change working directory before starting a daemon
        env => { # optional environment variables
            MOJO_FLAG_A => 1,
            MOJO_CONFIG => '...',
        },
        wait_status => { # optional wait until status will change state
            step    => 2, # default 0.1
            trials  => 4, # default 10
        },
        custom_commands => {
            ping => {
                my $self = shift; # Ubic::Service::Hypnotoad
                # any code
            }
        },
    });

=head1 DESCRIPTION

This service is a common ubic wrap for launching your applications with Hypnotoad.

=head1 ACTIONS

=head2 status

Get status of service.

=head2 start

Start service.

=head2 stop

Stop service

=head2 reload

Send a USR2 signal to the process, to have it do an "automatic hot deployment".

=head2 custom_action

Service specified commands

=cut

sub new {
	my ( $class, $opt ) = @_;

	my $bin =
	  ref $opt->{bin} eq 'ARRAY'
	  ? $opt->{bin}
	  : [ grep { length } split /\s+/x, ( $opt->{bin} // 'hypnotoad' ) ];
	@$bin or croak "missing 'bin' parameter in new";

	my $app = $opt->{app};
	length $app or croak "missing 'app' parameter in new";

	file_name_is_absolute($app)
	  or croak "The 'app' parameter must be an absolute path";
	my $pid_file = $opt->{pid_file}
	  // catfile( dirname($app), 'hypnotoad.pid' );

	file_name_is_absolute($pid_file)
	  or croak "The 'pid_file' parameter must be an absolute path";
	length $pid_file or croak "missing 'pid_file' parameter in new";

	my %env = %{ $opt->{env} // {} };

	my $wait_status = _calc_wait_status( $opt->{wait_status} );

	if ( $opt->{custom_commands} ) {
		for ( keys %{ $opt->{custom_commands} } ) {
			ref( $opt->{custom_commands}{$_} ) eq 'CODE'
			  or croak "Callback expected at custom command $_";
		}
	}

	return bless {
		bin             => $bin,
		app             => $app,
		env             => \%env,
		pid_file        => $pid_file,
		cwd             => $opt->{cwd},
		wait_status     => $wait_status,
		custom_commands => $opt->{custom_commands},
	}, $class;
}

sub _calc_wait_status {
	my $wait_status  = shift;
	my $step         = $wait_status->{step} // 0.1;
	my $trials       = $wait_status->{trials} // 10;
	my $time_to_wait = $step * ( $trials - 1 ) * $trials / 2 + 1;

	return +{
		step   => $step,
		trials => $trials,
	};
}

sub _read_pid {
	my $self = shift;

	unless ( -e $self->{pid_file} ) {
		return 0;
	}

	open my $fh, "<", $self->{pid_file} or croak;
	my $pid = ( scalar(<$fh>) =~ /(\d+)/gx )[0];
	close $fh;

	return $pid;
}

sub status_impl {
	my $self = shift;
	my $pid  = $self->_read_pid;

	if ( !$pid ) {
		return result('not running');
	}

	my ( $i, $running, $old_pid ) = (0);
	do {
		$i++;
		$old_pid = $pid;
		$running = kill 0, $old_pid;
		$pid     = $self->_read_pid or return result('not running');
	} while ( $pid == $old_pid && $i < 5 );

	$pid == $old_pid or return result('broken');

	return $running
	  ? result( 'running', 'pid ' . $pid )
	  : result('not running');
}

sub start_impl {
	my $self = shift;

	if ( defined $self->{cwd} ) {
		chdir $self->{cwd} or croak "chdir to '$self->{cwd}' failed: $!";
	}

	local %ENV = ( %ENV, %{ $self->{env} } );
	my ( undef, $stderr, $exit_status ) = capture {
		system( @{ $self->{bin} }, $self->{app} );
	};
	if ($exit_status) {
		carp $stderr if length $stderr;
		return result('broken');
	}

	return result('starting');
}

sub stop_impl {
	my $self = shift;

	if ( defined $self->{cwd} ) {
		chdir $self->{cwd} or croak "chdir to '$self->{cwd}' failed: $!";
	}

	local %ENV = ( %ENV, %{ $self->{env} } );
	my ( undef, $stderr, $exit_status ) = capture {
		system( @{ $self->{'bin'} }, '-s', $self->{'app'} );
	};
	if ($exit_status) {
		carp $stderr if length $stderr;
		return result('broken');
	}

	carp $stderr if length $stderr;

	return result('stopping');
}

sub custom_commands {
	my $self = shift;
	return keys %{ $self->{custom_commands} };
}

sub do_custom_command {
	my ( $self, $command ) = @_;
	unless ( exists $self->{custom_commands}{$command} ) {
		croak "Command '$command' not implemented";
	}
	return $self->{custom_commands}{$command}->($self);
}

sub reload {
	my $self = shift;

	my $pid = $self->_read_pid or return 'not running';
	my $ret = kill "USR2", $pid;
	return $ret ? 'reloaded' : 'not running';
}

sub timeout_options {
	my $self = shift;

	return {
		start => {
			step   => $self->{wait_status}{step},
			trials => $self->{wait_status}{trials},
		},
		stop => {
			step   => $self->{wait_status}{step},
			trials => $self->{wait_status}{trials},
		}
	};
}

=head1 BUGS

If you have a Github account, report your issues at
L<https://github.com/akarelas/ubic-service-hypnotoad/issues>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=cut

1;
