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
sub jumpstart {
    my $app     = shift;
    my ($param) = @_;
    my $q       = $app->query;
    my $blog_id = $q->param('blog_id');
    my $plugin  = MT->component('PubOffline');

    # We want to give up if PubOffline was not enabled on this blog.
    $param->{enabled} = $plugin->get_config_value(
        'enable_puboffline',
        'blog:' . $blog_id
    );

    # If the user has clicked "Jumpstart" to start the process, do it!
    if ( $q->param('jumpstart') ) {

        require PubOffline::Plugin;

        # Jumpstart assets
        my $iter = MT->model('asset')->load_iter({
            blog_id => $blog_id,
            class   => '*', # Grab all assets in this blog
        });

        while ( my $asset = $iter->() ) {
            # Move on if this asset doesn't have a file path (it's not a
            # file-based asset) or if the asset file doesn't exist.
            next if !$asset->file_path || !-e $asset->file_path;

            PubOffline::Plugin::_create_asset_handling_job( $asset );
        }

        # Jumpstart static files
        PubOffline::Plugin::_create_static_handling_jobs( $blog_id );

        return $plugin->load_tmpl( 'dialog/close.tmpl' );
    }

    $param->{blog_id} = $blog_id;

    return $plugin->load_tmpl( 'dialog/jumpstart.tmpl', $param );
}

1;

__END__
