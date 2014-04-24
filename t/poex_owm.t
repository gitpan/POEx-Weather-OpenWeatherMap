use Test::More;
use strict; use warnings FATAL => 'all';

my $mocked_response = 0;

{ package
    MockHTTPClientSession;
  use strict; use warnings FATAL => 'all';
  use POE;
  use Weather::OpenWeatherMap::Test;

  POE::Session->create(
    inline_states => +{
      _start  => sub {
        $_[KERNEL]->alias_set( 'mockua' );
      },
      request => sub {
        my ($post_to, $http_req, $my_req) = @_[ARG0 .. $#_];
        my $http_response = mock_http_ua->request($http_req);
        $poe_kernel->post( $_[SENDER], $post_to,
          [ $http_req, $my_req ],
          [ $http_response ],
        );
        $mocked_response++;
        $_[KERNEL]->alias_remove( 'mockua' ) if $mocked_response == 2;
      },
    },
  );
}


use POE;
use POEx::Weather::OpenWeatherMap;

my $got = +{};
my $expected = +{
  'current weather ok'  => 1,
  'forecast weather ok' => 1,
};

POE::Session->create(
  inline_states => +{
    _start => sub {
      $_[HEAP]->{wx} = POEx::Weather::OpenWeatherMap->new(
        api_key => 'foo',
        event_prefix => 'pwx_',
        ua_alias => 'mockua',
      );

      $_[HEAP]->{wx}->start;

      # pwx_weather
      $_[HEAP]->{wx}->get_weather(
        location => 'Manchester, NH',
        tag      => 'mytag',
      );

      # pwx_forecast
      $_[HEAP]->{wx}->get_weather(
        location => 'Manchester, NH',
        forecast => 1,
        days     => 3,
      );

      $_[HEAP]->{secs} = 0;
      $_[KERNEL]->delay( check_if_done => 1 );
    },
    pwx_weather => sub {
      my $res = $_[ARG0];
      $got->{'current weather ok'}++
        if $res->name eq 'Manchester';
    },
    pwx_forecast => sub {
      my $res = $_[ARG0];
      $got->{'forecast weather ok'}++
        if $res->name eq 'Manchester'
        and $res->isa('Weather::OpenWeatherMap::Result::Forecast');
    },
    check_if_done => sub {
      my $done = keys %$expected == keys %$got ? 1 : 0;
      $_[HEAP]->{secs}++;
      if ($_[HEAP]->{secs} == 60) {
        $_[HEAP]->{wx}->stop;
        $done++;
        fail "Timed out"
      }
      $_[HEAP]->{wx}->stop if $done;
      $_[KERNEL]->delay( check_if_done => 1 ) unless $done;
    },
  },
);

POE::Kernel->run;

ok $mocked_response == 2, 'mocked 2 responses ok';
is_deeply $got, $expected, 'got expected results ok';

done_testing