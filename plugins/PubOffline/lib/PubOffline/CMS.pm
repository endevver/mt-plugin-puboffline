package PubOffline::CMS;

use strict;
use warnings;

# The plugin Settings screen. We need to use a subroutine because the blog ID
# isn't made available when only a template is supplied.
sub settings {
    my ($plugin, $param, $scope) = @_;
    my $app = MT->instance;

    # We need the blog ID to make the Jumpstart button work.
    $param->{blog_id} = $app->blog->id;

    return $plugin->load_tmpl( 'blog_config.tmpl', $param );
}

# Use a popup window for the process of "jumpstarting" assets -- sending them
# all to the PQ to be handled for offline use. This is used both for the
# initial loading of the jumpstart dialog, and to do the actual jumpstart
sub jumpstart_assets {
    my $app     = shift;
    my ($param) = @_;
    my $q       = $app->query;
    my $plugin  = MT->component('PubOffline');

    # We want to give up if PubOffline was not enabled on this blog.
    $param->{enabled} = $plugin->get_config_value(
        'enable_puboffline',
        'blog:' . $q->param('blog_id')
    );

    # If the user has clicked "Jumpstart" to start the process, do it!
    if ( $q->param('jumpstart') ) {
        my $iter = MT->model('asset')->load_iter({
            blog_id => $q->param('blog_id'),
            class   => '*', # Grab all assets in this blog
        });

        require PubOffline::Plugin;
        
        while ( my $asset = $iter->() ) {
            PubOffline::Plugin::_create_asset_handling_job( $asset );
        }

        return $plugin->load_tmpl( 'dialog/close.tmpl' );
    }

    $param->{blog_id} = $q->param('blog_id');

    return $plugin->load_tmpl( 'dialog/jumpstart_assets.tmpl', $param );
}

1;

__END__
