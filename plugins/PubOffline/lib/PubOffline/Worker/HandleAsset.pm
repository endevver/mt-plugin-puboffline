package PubOffline::Worker::HandleAsset;

use strict;
use warnings;
use base qw( TheSchwartz::Worker );

use TheSchwartz::Job;
use Time::HiRes qw(gettimeofday tv_interval);
use PubOffline::Util qw( get_output_path path_exists );
use File::Copy::Recursive qw(fcopy);
use File::Basename;

sub keep_exit_status_for { 1 }

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;
    my $plugin = MT->component('PubOffline');

    # Build this
    my $mt = MT->instance;

    # reset publish timer; don't republish a file if it has
    # this or a later timestamp.
    $mt->publisher->start_time( time );

    # We got triggered to build; lets find coalescing jobs
    # and process them in one pass.

    my @jobs = ($job);
    my $job_iter;
    if (my $key = $job->coalesce) {
        $job_iter = sub {
            shift @jobs || MT::TheSchwartz->instance->find_job_with_coalescing_value($class, $key);
        };
    }
    else {
        $job_iter = sub { shift @jobs };
    }

    my $start = [gettimeofday];
    my $rebuilt = 0;

    while (my $job = $job_iter->()) {
        # Load the job, and use that to get at the asset ID so that the asset
        # can be loaded.
        my $mt_job = MT->model('ts_job')->load( $job->jobid );
        my $asset_id = $job->uniqkey;
        my $asset = MT->model('asset')->load( $asset_id )
            or next;

        # If there is no file path for this asset, just move on to the next
        # job. No file path means this isn't a file-based asset, so there's
        # nothing for us to do. Also check that the asset exists at that
        # location; if not there, give up because we can't copy something that
        # doesn't exist.
        next if !$asset->file_path || !-e $asset->file_path;

        my $output_file_path = get_output_path({ 
            blog_id => $asset->blog_id,
        });

        my $result = path_exists({
            blog_id => $asset->blog_id,
            path    => $output_file_path,
        });
        next if !$result; # Give up if the path wasn't created.

        # How is this blog supposed to handle assets: copy or hard link?
        my $pref = $plugin->get_config_value(
            'asset_handling',
            'blog:' . $asset->blog_id,
        );

        $result = undef;
        if ($pref eq 'hard_link') {
            $result = _hard_link_asset({
                output_file_path => $output_file_path,
                asset            => $asset,
            });
        }
        # Fall back to copying the asset.
        else {
            $result = _copy_asset({
                output_file_path => $output_file_path,
                asset            => $asset,
            });
        }


        if (defined $result) {
            $job->completed();
            $rebuilt++;

            MT->log({
                blog_id => $asset->blog_id,
                message => 'PubOffline: The asset ' 
                    . ($asset->label . ' (' . $asset->file_name . ') '
                        || $asset->file_name)
                    . 'was successfully updated.',
                level   => MT::Log::INFO(),
            });
        } else {
            # The error was already reported and logged in _hard_link or
            # _copy_asset so we don't need to do anything.
        }
    }
}

sub grab_for { 60 }
sub max_retries { 0 }
sub retry_delay { 60 }

# Copy the asset from the online to offline location. (We're copying based on
# the plugin Setting for asset handling.)
sub _copy_asset {
    my ($arg_refs)       = @_;
    my $output_file_path = $arg_refs->{output_file_path};
    my $asset            = $arg_refs->{asset};

    my $blog = MT->model('blog')->load( $asset->blog_id )
        or return 0;

    my $blog_site_path = $blog->site_path;
    $blog_site_path = $blog_site_path . '/' if $blog_site_path !~ /\/$/;

    # Create a relative path that can be used to properly create the online
    # and offline paths.
    my $rel_file_path = $asset->file_path;
    $rel_file_path =~ s/$blog_site_path//;

    my $source = File::Spec->catfile($blog_site_path, $rel_file_path);
    my $dest   = File::Spec->catfile($output_file_path, $rel_file_path);

    # Check if the file to be published is in the Exclude File Manifest,
    # which would mean we should skip outputting this file. Build a regex
    # using alternation to find a matching path or a partial match of a
    # path (such as may be used to exclude an entire directory).
    my @paths = get_exclude_manifest({ blog_id => $blog->id });
    my $pattern = join('|', @paths);
    if ( $dest =~ /($pattern)/ ) {
        # The current file is in the Exclude File Manifest. Don't output
        # this file, and try to delete it if it exists.
        unlink $dest
            if (-e $dest);

        MT->log({
            level   => MT->model('log')->INFO(),
            blog_id => $asset->blog_id,
            message => "PubOffline: the asset $dest has been excluded from "
                . "the offline site."
        });
        return 1;
    }

    # Finally, copy the asset.
    my $result = fcopy( $source, $dest );

    if (!$result) {
        my $errmsg = MT->translate(
            "PubOffline: Error copying asset ID [_1] ([_2]) to target "
                . "directory: [_3]", 
            $asset->id,
            $source, 
            $dest
        );
        MT::TheSchwartz->debug($errmsg);
        MT->log({
            blog_id => $asset->blog_id,
            message => $errmsg,
            level   => MT::Log::ERROR(),
        });
    }

    return 1;
}

# Create a hard link of the asset from the online to offline location. (We're
# creating the hard link based on the plugin Setting for asset handling.)
sub _hard_link_asset {
    my ($arg_refs)       = @_;
    my $output_file_path = $arg_refs->{output_file_path};
    my $asset            = $arg_refs->{asset};

    my $blog = MT->model('blog')->load( $asset->blog_id )
        or return 0;

    my $blog_site_path = $blog->site_path;
    $blog_site_path = $blog_site_path . '/' if $blog_site_path !~ /\/$/;

    # Create a relative path that can be used to properly create the online
    # and offline paths.
    my $rel_file_path = $asset->file_path;
    $rel_file_path =~ s/$blog_site_path//;

    my $source = File::Spec->catfile($blog_site_path, $rel_file_path);
    my $dest   = File::Spec->catfile($output_file_path, $rel_file_path);

    # Check if the file to be published is in the Exclude File Manifest,
    # which would mean we should skip outputting this file. Build a regex
    # using alternation to find a matching path or a partial match of a
    # path (such as may be used to exclude an entire directory).
    my @paths = get_exclude_manifest({ blog_id => $blog->id });
    my $pattern = join('|', @paths);
    if ( $dest =~ /($pattern)/ ) {
        # The current file is in the Exclude File Manifest. Don't output
        # this file, and try to delete it if it exists.
        unlink $dest
            if (-e $dest);

        MT->log({
            level   => MT->model('log')->INFO(),
            blog_id => $asset->blog_id,
            message => "PubOffline: the asset $dest has been excluded from "
                . "the offline site."
        });
        return 1;
    }

    # If the link already exists we can just give up -- since the link exists
    # it already points to the latest data. (It's also worth noting that 
    # creating a link when a link already exists just throws an error.)
    return 1 if -e $dest;

    # Grab the path to the file (undef is the filename).
    my (undef, $path) = fileparse($dest);

    # Create the parent directory structure before trying to
    # link the file.
    my $fmgr = MT::FileMgr->new('Local')
        or die MT::FileMgr->errstr;
    $fmgr->mkpath( $path )
        or die MT::FileMgr->errstr;

    # Create the hard link.
    my $result = link( $source, $dest );

    if (!$result) {
        my $errmsg = MT->translate(
            "PubOffline: Error creating hard link for asset ID [_1] ([_2]) "
                . "to target directory: [_3]", 
            $asset->id,
            $source, 
            $dest
        );
        MT::TheSchwartz->debug($errmsg);
        MT->log({
            blog_id => $asset->blog_id,
            message => $errmsg,
            level   => MT::Log::ERROR(),
        });
    }

    return 1;
}

1;

__END__
