package POEx::Weather::OpenWeatherMap;
$POEx::Weather::OpenWeatherMap::VERSION = '0.001001';
use v5.10;
use strictures 1;
use Carp;

use List::Objects::Types -all;
use Types::Standard      -all;

use POE 'Component::Client::HTTP';

use Weather::OpenWeatherMap::Error;
use Weather::OpenWeatherMap::Request;
use Weather::OpenWeatherMap::Result;


use Moo; use MooX::late;
with 'MooX::Role::POE::Emitter';


has api_key => (
  lazy        => 1,
  is          => 'ro',
  isa         => Str,
  predicate   => 1,
  builder     => sub { '' },
);

has _in_shutdown => (
  is          => 'rw',
  isa         => Bool,
  default     => sub { 0 },
);

has _ua_alias => (
  lazy        => 1,
  init_arg    => 'ua_alias',
  is          => 'ro',
  isa         => Str,
  builder     => sub {
    my ($self) = @_;
    $self->alias ? $self->alias . 'UA'
      : confess "Cannot build ua_alias; emitter not running"
  },
);


sub start {
  my ($self) = @_;
  $self->_in_shutdown(0) if $self->_in_shutdown;
  $self->set_object_states(
    [
      $self => +{
        emitter_started  => 'mxrp_emitter_started',
        emitter_stopped  => 'mxrp_emitter_stopped',

        get_weather        => 'ext_get_weather',
        ext_http_response  => 'ext_http_response',
      },

      ( $self->has_object_states ? $self->object_states->all : () ),
    ]
  );
  $self->_start_emitter
}

sub stop {
  my ($self) = @_;
  $self->_in_shutdown(1);
  $self->_shutdown_emitter
}

sub _emit_error {
  my $self = shift;
  my $err = Weather::OpenWeatherMap::Error->new(@_);
  $self->emit( error => $err );
  $err
}


sub mxrp_emitter_started {
#  my ($kernel, $self) = @_[KERNEL, OBJECT];
}

sub mxrp_emitter_stopped {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  $kernel->post( $self->_ua_alias => 'shutdown' )
    if $kernel->alias_resolve( $self->_ua_alias );
}

sub get_weather {
  my $self = shift;
  $self->yield(get_weather => @_)
}

sub ext_get_weather {
  my $self = $_[OBJECT];
  my %args = @_[ARG0 .. $#_];

  my $location = $args{location};
  unless ($location) {
    warn "Missing 'location =>' in query\n";
    my $fake_req = Weather::OpenWeatherMap::Request->new_for(
      Current =>
        tag      => $args{tag},
        location => '',
    );
    $self->_emit_error(
      source  => 'internal',
      request => $fake_req,
      status  => "Missing 'location =>' in query",
    );
    return
  }

  my $type = delete $args{forecast} ? 'Forecast' : 'Current';

  my $my_request = Weather::OpenWeatherMap::Request->new_for(
    $type =>
      ( 
        $self->has_api_key && length $self->api_key ?
          (api_key => $self->api_key) : () 
      ),
      %args
  );

  $self->_issue_http_request($my_request)
}


sub _issue_http_request {
  my ($self, $my_request) = @_;

  unless ( $poe_kernel->alias_resolve($self->_ua_alias) ) {
    POE::Component::Client::HTTP->spawn(
      Alias           => $self->_ua_alias,
      FollowRedirects => 2,
    )
  }

  $poe_kernel->post( $self->_ua_alias => request => ext_http_response =>
    $my_request->http_request,
    $my_request
  );
}


sub ext_http_response {
  my $self = $_[OBJECT];

  return if $self->_in_shutdown;

  my (undef, $my_request) = @{ $_[ARG0] };
  my ($http_response)     = @{ $_[ARG1] };

  unless ($http_response->is_success) {
    $self->_emit_error(
      source  => 'http',
      request => $my_request,
      status  => $http_response->status_line,
    );
    return
  }

  state $base = 'Weather::OpenWeatherMap::Request::';
  my ($type, $event);
  CLASS: {
    if ($my_request->isa($base.'Current')) {
      $type  = 'Current';
      $event = 'weather';
      last CLASS
    }
    
    if ($my_request->isa($base.'Forecast')) {
      $type  = 'Forecast';
      $event = 'forecast';
      last CLASS
    }

    confess "Unknown request type: $my_request"
  } # CLASS

  my $content = $http_response->content;
  my $my_response = Weather::OpenWeatherMap::Result->new_for(
    $type =>
      request => $my_request,
      json    => $content,
  );
  
  unless ($my_response->is_success) {
    my $code = $my_response->response_code;
    $self->_emit_error(
      source  => 'api',
      request => $my_request,
      status  => "$code: ".$my_response->error,
    );
    return
  }

  $self->emit( 
    $event => $my_response 
  );
}

1;


=pod

=for Pod::Coverage ext_\w+ mxrp_\w+ has_\w+

=head1 NAME

POEx::Weather::OpenWeatherMap - POE-enabled OpenWeatherMap client

=head1 SYNOPSIS

  use POE;
  use POEx::Weather::OpenWeatherMap;

  my $api_key = 'foo';

  POE::Session->create(
    package_states => [
      main => [qw/
        _start
        
        pwx_error
        pwx_weather
        pwx_forecast
      /],
    ],
  );

  sub _start {
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    
    # Create and start emitter:
    my $wx = POEx::Weather::OpenWeatherMap->new(
      api_key      => $api_key,
      event_prefix => 'pwx_',
    );

    $heap->{wx} = $wx;
    $wx->start;

    ## An example request:
    $wx->get_weather(
      location => 'Manchester, NH',
      tag      => 'mytag',
    );
  }

  sub pwx_error {
    my $err = $_[ARG0];
    my $status  = $err->status;
    my $request = $err->request;
    # ... do something with error ...
    warn "Error! ($status)";
  }

  sub pwx_weather {
    my $result = $_[ARG0];

    my $tag = $result->request->tag;

    my $place = $result->name;

    my $tempf = $result->temp_f;
    my $conditions = $result->conditions_verbose;
    # (see Weather::OpenWeatherMap::Result::Current for a method list)
    # ...
  }

  sub pwx_forecast {
    my $result = $_[ARG0];

    my $place = $result->name;

    my $itr = $result->iter;
    while (my $day = $itr->()) {
      my $date = $day->dt->mdy;
      my $temp_hi = $day->temp_max_f;
      my $temp_lo = $day->temp_min_f;
      # (see Weather::OpenWeatherMap::Result::Forecast)
      # ...
    }
  }

  POE::Kernel->run;

=head1 DESCRIPTION

A POE-enabled interface to OpenWeatherMap (L<http://www.openweathermap.org>),
providing an object-oriented asynchronous interface to current & forecast
weather conditions for a given city, latitude/longitude, or OpenWeatherMap
city code.

This is really just an asynchronous counterpart to L<Weather::OpenWeatherMap>;
look there for documentation regarding Request & Result objects.

This an event emitter that consumes L<MooX::Role::POE::Emitter>; look there
for documentation on composed methods. See L<http://www.openweathermap.org>
for more on OpenWeatherMap itself.

=head2 ATTRIBUTES

=head3 api_key

Your L<OpenWeatherMap|http://www.openweathermap.org> API key.

(See L<http://www.openweathermap.org/api> to register for free.)

=head2 METHODS

=head3 start

Start our session.

Must be called before events will be received or emitted.

=head3 stop

Stop our session, shutting down the emitter and user agent (which will cancel
pending requests).

=head3 get_weather

  $wx->get_weather(
    # 'location =>' is mandatory.
    #  These are all valid location strings:
    #  By name:
    #   'Manchester, NH'
    #   'London, UK'
    #  By OpenWeatherMap city code:
    #   5089178
    #  By latitude/longitude:
    #   'lat 42, long -71'
    location => 'Manchester, NH',

    # Set 'forecast => 1' to get the forecast,
    # omit or set to false for current weather:
    forecast => 1,

    # If 'forecast' is true, you can specify the number of days to fetch
    # (up to 14):
    days => 3,

    # Optional tag for identifying the response to this request:
    tag  => 'foo',
  );

Request a weather report for the given C<< location => >>.

The location can be a 'City, State' or 'City, Country' string, an
L<OpenWeatherMap|http://www.openweathermap.org/> city code, or a 'lat X, long
Y' string.

Requests the current weather by default (see
L<Weather::OpenWeatherMap::Request::Current>).

If passed C<< forecast => 1 >>, requests a weather forecast (see
L<Weather::OpenWeatherMap::Request::Forecast>), in which case C<< days
=> $count >> can be specified (up to 14).

An optional C<< tag => >> can be specified to identify the response when it
comes in.

Any extra arguments are passed to the constructor for the appropriate Request
subclass; see L<Weather::OpenWeatherMap::Request>.

The request is made asynchronously and a response (or error) emitted when it
is available; see L</EMITTED EVENTS>. There is no useful return value.

=head2 RECEIVED EVENTS

=head3 get_weather

  $poe_kernel->post( $wx->session_id =>
    get_weather =>
      location => 'Manchester, NH',
      tag      => 'foo',
  );

POE interface to the L</get_weather> method; see L</METHODS> for available
options.

=head2 EMITTED EVENTS

=head3 error

Emitted when an error occurs; this may be an internal error, an HTTP error,
or an error reported by the OpenWeatherMap API.

C<$_[ARG0]> is a L<Weather::OpenWeatherMap::Error> object.

=head3 weather

Emitted when a request for the current weather has been successfully processed.

C<$_[ARG0]> is a L<Weather::OpenWeatherMap::Result::Current> object; see
that module's documentation for details on retrieving weather information.

=head3 forecast

Emitted when a request for a weather forecast has been successfully processed.

C<$_[ARG0]> is a L<Weather::OpenWeatherMap::Result::Forecast> object;
see that module's documentation for details on retrieving per-day forecasts
(L<Weather::OpenWeatherMap::Result::Forecast::Day> objects).

=head1 SEE ALSO

L<Weather::OpenWeatherMap>

L<Weather::OpenWeatherMap::Error>

L<Weather::OpenWeatherMap::Result>

L<Weather::OpenWeatherMap::Result::Current>

L<Weather::OpenWeatherMap::Result::Forecast>

L<Weather::OpenWeatherMap::Request>

L<Weather::OpenWeatherMap::Request::Current>

L<Weather::OpenWeatherMap::Request::Forecast>

The C<examples/> directory of this distribution.

=head1 AUTHOR

Jon Portnoy <avenj@cobaltirc.org>

=cut

# vim: ts=2 sw=2 et sts=2 ft=perl
