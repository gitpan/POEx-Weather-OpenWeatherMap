
BEGIN {
  unless ($ENV{RELEASE_TESTING}) {
    require Test::More;
    Test::More::plan(skip_all => 'these tests are for release candidate testing');
  }
}

use strict;
use warnings;

# this test was generated with Dist::Zilla::Plugin::Test::NoTabs 0.07

use Test::More 0.88;
use Test::NoTabs;

my @files = (
    'lib/POEx/Weather/OpenWeatherMap.pm',
    't/00-report-prereqs.t',
    't/poex_owm.t',
    't/release-cpan-changes.t',
    't/release-dist-manifest.t',
    't/release-no-tabs.t',
    't/release-pod-coverage.t',
    't/release-pod-linkcheck.t',
    't/release-pod-syntax.t',
    't/release-synopsis.t',
    't/release-unused-vars.t'
);

notabs_ok($_) foreach @files;
done_testing;
