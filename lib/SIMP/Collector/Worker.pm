package SIMP::Collector::Worker;

use strict;
use warnings;

use Moo;
use AnyEvent;
use Data::Dumper;

use GRNOC::RabbitMQ::Client;
use GRNOC::RabbitMQ::Dispatcher;
use GRNOC::RabbitMQ::Method;
use SIMP::Collector;
use SIMP::Collector::TSDSPusher;

has worker_name => (is => 'ro',
		    required => 1);

has logger => (is => 'rwp',
	       required => 1);

has simp_config => (is => 'rwp',
		    required => 1);

has tsds_config => (is => 'rwp',
		    required => 1);

has hosts => (is => 'rwp',
	      required => 1);

has tsds_type => (is => 'rwp',
                  required => 1);

has interval => (is => 'rwp',
		 required => 1);

has composite_name => (is => 'rwp',
		       required => 1);

has filter_name => (is => 'rwp');
has filter_value => (is => 'rwp');

has simp_client => (is => 'rwp');
has tsds_pusher => (is => 'rwp');
has poll_w => (is => 'rwp');
has push_w => (is => 'rwp');
has msg_list => (is => 'rwp', default => sub { [] });
has cv => (is => 'rwp');
has stop_me => (is => 'rwp', default => 0);

# 
# Run worker
#
sub run {
    my ($self) = @_;

    $0 = $self->worker_name;

    # Set logging object
    $self->_set_logger(Log::Log4perl->get_logger('SIMP.Collector.Worker'));

    # Set worker properties
    $self->_load_config();

    # Enter event loop, loop until condvar met
    $self->logger->info("Entering event loop");
    $self->_set_cv(AnyEvent->condvar());
    $self->cv->recv;

    $self->logger->info($self->worker_name . " loop ended, terminating");
}

#
# Load config
#
sub _load_config {
    my ($self) = @_;
    $self->logger->info($self->worker_name . " starting");

    # Create dispatcher to watch for messages from Master
    my $dispatcher = GRNOC::RabbitMQ::Dispatcher->new(
	host => $self->simp_config->{'host'},
	port => $self->simp_config->{'port'},
	user => $self->simp_config->{'user'},
	pass => $self->simp_config->{'password'},
	exchange => 'SNAPP',
	topic    => "SNAPP." . $self->worker_name
    );

    # Create and register stop method
    my $stop_method = GRNOC::RabbitMQ::Method->new(
	name        => "stop",
	description => "stops worker",
	callback => sub {
	    $self->_set_stop_me(1);
	}
    );
    $dispatcher->register_method($stop_method);

    # Create SIMP client object
    $self->_set_simp_client(GRNOC::RabbitMQ::Client->new(
	host => $self->simp_config->{'host'},
	port => $self->simp_config->{'port'},
	user => $self->simp_config->{'user'},
	pass => $self->simp_config->{'password'},
	exchange => 'Simp',
	topic    => 'Simp.CompData'
    ));

    # Create TSDS Pusher object
    $self->_set_tsds_pusher(SIMP::Collector::TSDSPusher->new(
	logger => $self->logger,
	worker_name => $self->worker_name,
	tsds_config => $self->tsds_config,
    ));

    # set interval
    my $interval = $self->interval;

    # set composite name
    my $composite = $self->composite_name;

    # Create polling timer for event loop
    $self->_set_poll_w(AnyEvent->timer(
	after => 5,
	interval => $interval,
	cb => sub {
	    my $tm = time;
	
	    # Pull data for each host from Comp
	    foreach my $host (@{$self->hosts}) {
		$self->logger->info($self->worker_name . " processing $host");
		
		my %args = (
		    node           => $host,
		    period         => $interval,
		    async_callback => sub {
			my $res = shift;
			
			# Process results and push when idle
			$self->_process_host($res, $tm);
			$self->_set_push_w(AnyEvent->idle(cb => sub { $self->_push_data; }));
		    }
		    );

		# if we're trying to only get a subset of values out of simp,
 		# add those arguments now. This presumes that SIMP and SIMP-collector
		# have been correctly configured to have the data available
		# validity is checked for earlier in Master
		if ($self->filter_name){
		    $args{$self->filter_name} = $self->filter_value;
		}

		$self->simp_client->$composite(%args);
	    }

	    # Push when idle
	    $self->_set_push_w(AnyEvent->idle(cb => sub { $self->_push_data; }));
	}
    ));
    
    $self->logger->info($self->worker_name . " Done setting up event callbacks");
}

#
# Process host for publishing to TSDS
#
sub _process_host {
    my ($self, $res, $tm) = @_;

    # Drop out if we get an error from Comp
    if (!defined($res) || $res->{'error'}) {
	$self->logger->error($self->worker_name . " Comp error: " . SIMP::Collector::error_message($res));
	return;
    }

    # Take data from Comp and "package" for a post to TSDS
    foreach my $node_name (keys %{$res->{'results'}}) {

	$self->logger->debug($self->worker_name . ' Name: ' . Dumper($node_name));
	$self->logger->debug($self->worker_name . ' Value: ' . Dumper($res->{'results'}->{$node_name}));

	my $data = $res->{'results'}->{$node_name};
	foreach my $datum_name (keys %{$data}) {
	    my $datum = $data->{$datum_name};
	    my %vals;
	    my %meta;
	    my $datum_tm = $tm;

	    foreach my $key (keys %{$datum}) {
		next if !defined($datum->{$key});

		if ($key eq 'time') {
		    $datum_tm = $datum->{$key} + 0;
		} elsif ($key =~ /^\*/) {
		    my $meta_key = substr($key, 1);
		    $meta{$meta_key} = $datum->{$key};
		} else {
		    $vals{$key} = $datum->{$key} + 0;
		}
	    }
 
	    # Needed to handle bug in 3135:160
	    next if ($self->tsds_type eq 'interface') && (!defined($vals{'input'}) || !defined($vals{'output'}));

	    # push onto our queue for posting to TSDS
	    push @{$self->msg_list}, {
		type => $self->tsds_type,
		time => $datum_tm,
		interval => $self->interval,
		values => \%vals,
		meta => \%meta
	    };
	}
    }
}

#
# Push to TSDS
#
sub _push_data {
    my ($self) = @_;
    my $msg_list = $self->msg_list;
    my $res = $self->tsds_pusher->push($msg_list);
    $self->logger->debug( Dumper($msg_list) );
    $self->logger->debug( Dumper($res) );

    unless ($res) {
	# If queue is empty and stop flag is set, end event loop
	$self->cv->send() if $self->stop_me;
	# Otherwise clear push timer
	$self->_set_push_w(undef);
	exit(0) if $self->stop_me;
    }
}

1;
