use ExtUtils::MakeMaker;

use YAML::Any qw(LoadFile);
my $file = "plugins/PubOffline/config.yaml";
my $version = LoadFile($file)->{version} ||
    die "No version found in $file";

WriteMakefile(
    NAME            => 'Publish Offline',
    VERSION         => $version,
    DISTNAME        => 'PubOffline',
);
