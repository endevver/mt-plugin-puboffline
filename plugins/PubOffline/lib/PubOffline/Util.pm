package PubOffline::Util;

use strict;
use warnings;

use base 'Exporter';

our @EXPORT_OK = qw( get_output_path );

# The output file path is set in the plugin's Settings, and can contain MT
# tags. If the output file path contains any MT tags, we want to render those
# before trying to use output_file_path.
sub get_output_path {
    my ($arg_refs) = @_;
    my $blog_id = $arg_refs->{blog_id};
    my $plugin = MT->component('PubOffline');

    # If the output file path contains any MT tags, we want to render
    # those before trying to use output_file_path.
    my $output_file_path = $plugin->get_config_value(
        'output_file_path',
        'blog:' . $blog_id
    );

    # Add a trailing slash, if needed.
    $output_file_path = $output_file_path . '/' if $output_file_path !~ /\/$/;

    use MT::Template::Context;
    my $ctx = MT::Template::Context->new;
    # Blog ID needs to be set to get into the correct context.
    $ctx->stash('blog_id', $blog_id );

    # Render the tags with a template object that isn't saved.
    my $output_file_path_tmpl = MT::Template->new();
    $output_file_path_tmpl->text( $output_file_path );
    $output_file_path_tmpl->blog_id( $blog_id );

    my $result = $output_file_path_tmpl->build($ctx)
        or die $output_file_path_tmpl->errstr;

    return $result;
}

1;

__END__
