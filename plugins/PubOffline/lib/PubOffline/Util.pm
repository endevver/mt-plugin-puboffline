package PubOffline::Util;

use strict;
use warnings;

use base 'Exporter';

our @EXPORT_OK = qw( 
    get_output_path get_output_url get_archive_path render_template 
    path_exists get_exclude_manifest
);

# The output file path is set in the plugin's Settings, and can contain MT
# tags. If the output file path contains any MT tags, we want to render those
# before trying to use output_file_path.
sub get_output_path {
    my ($arg_refs) = @_;
    my $blog_id = $arg_refs->{blog_id};
    my $plugin = MT->component('PubOffline');

    my $path = $plugin->get_config_value(
        'output_file_path',
        'blog:' . $blog_id
    );
    
    return '' if !$path;

    # Add a trailing slash, if needed.
    $path = $path . '/' if $path !~ /\/$/;

    # If a template tag was used here, we want it rendered.
    $path = render_template({
        blog_id => $blog_id,
        text    => $path,
    });

    return $path;
}

# The output file URL is set in the plugin's Settings, and can contain MT
# tags. If the output file URL contains any MT tags, we want to render those
# before trying to use it.
sub get_output_url {
    my ($arg_refs) = @_;
    my $blog_id = $arg_refs->{blog_id};
    my $plugin = MT->component('PubOffline');

    my $url = $plugin->get_config_value(
        'output_file_url',
        'blog:' . $blog_id
    );
    
    return '' if !$url;

    # Add a trailing slash, if needed.
    $url = $url . '/' if $url !~ /\/$/;

    # If a template tag was used here, we want it rendered.
    $url = render_template({
        blog_id => $blog_id,
        text    => $url,
    });

    return $url;
}

# The offline archive file path is set in the plugin's Settings, and can
# contain MT tags. If the output file path contains any MT tags, we want to
# render those before trying to use it.
sub get_archive_path {
    my ($arg_refs) = @_;
    my $blog_id = $arg_refs->{blog_id};
    my $plugin = MT->component('PubOffline');

    my $path = $plugin->get_config_value(
        'offline_archives_path',
        'blog:' . $blog_id
    );

    return '' if !$path;

    # Add a trailing slash, if needed.
    $path = $path . '/' if $path !~ /\/$/;

    # If a template tag was used here, we want it rendered.
    $path = render_template({
        blog_id => $blog_id,
        text    => $path,
    });

    return $path;
}

# Template tags can be specified in the plugin Settings. Render them before
# trying to use them.
sub render_template {
    my ($arg_refs) = @_;
    my $blog_id    = $arg_refs->{blog_id};
    my $text       = $arg_refs->{text};

    use MT::Template::Context;
    my $ctx = MT::Template::Context->new;
    # Blog ID needs to be set to get into the correct context.
    $ctx->stash('blog_id', $blog_id );

    # Render the tags with a template object that isn't saved.
    my $tmpl = MT::Template->new();
    $tmpl->text( $text );
    $tmpl->blog_id( $blog_id );

    my $result = $tmpl->build($ctx)
        or die $tmpl->errstr;

    return $result;
}

# Does the specified path exist? If not, create it.
sub path_exists {
    my ($arg_refs) = @_;
    my $blog_id    = $arg_refs->{blog_id};
    my $path       = $arg_refs->{path};

    # If the path already exists, then we're done!
    return 1 if -d $path;

    # It doesn't exist, so let's create it.
    require MT::FileMgr;
    my $fmgr = MT::FileMgr->new('Local')
        or die MT::FileMgr->errstr;

    # Try to create the output file path specified. If it fails,
    # record a note in the Activity Log and move on to the next job.
    my $result = $fmgr->mkpath( $path );

    if ($result) {
        return 1; # Path successfully created.
    }
    # Failed creating the path.
    else {
        MT->log({
            level   => MT->model('log')->ERROR(),
            blog_id => $blog_id,
            message => "PubOffline could not write to the Output File "
                . "Path ($path) as specified in the plugin Settings. "
                . $fmgr->errstr,
        });
        
        return 0;
    }
}

# Get the Exclude File Manifest contents and build an array of files to *not*
# be exported.
sub get_exclude_manifest {
    my ($arg_refs) = @_;
    my $blog_id = $arg_refs->{blog_id};
    my $plugin = MT->component('PubOffline');
    my @paths;

    my $manifest = $plugin->get_config_value(
        'exclude_manifest',
        'blog:' . $blog_id
    );

    return @paths if !$manifest;

    my $output_file_path = get_output_path({ blog_id => $blog_id });

    # Split the saved manifest contents on new lines, then process each item.
    # Items are specified with a relative path; prepend the Offline Output
    # Path so that they are absolute.
    my @files = split(/\s*[\r\n]\s*/, $manifest);
    foreach my $file ( @files ) {
        push @paths, File::Spec->catfile($output_file_path, $file);
    }

    return @paths;
}

1;

__END__
