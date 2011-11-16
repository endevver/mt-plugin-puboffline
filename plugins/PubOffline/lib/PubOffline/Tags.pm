package PubOffline::Tags;

use strict;
use warnings;

sub is_offline {
    my ( $ctx, $args, $cond ) = @_;
    my $bool = $ctx->stash('__offline_mode');
    return $bool ? 1 : 0;
}

1;

__END__
