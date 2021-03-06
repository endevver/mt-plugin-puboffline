package PubOffline::CMS;

use strict;
use warnings;

use PubOffline::Util qw( get_output_path get_output_url get_archive_path );

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

            PubOffline::Plugin::_create_asset_handling_job({
                asset     => $asset,
                jumpstart => 1,
            });
        }

        # Jumpstart static files
        PubOffline::Plugin::_create_static_handling_jobs({
            blog_id   => $blog_id,
            jumpstart => 1,
        });

        # Jumpstart templates: indexes and archives.
        my $fi_iter = MT->model('fileinfo')->load_iter({
            blog_id => $blog_id,
        });

        while ( my $fi = $fi_iter->() ) {
            # Try loading the template identified in the fileinfo record.
            # Continue if it is not a backup template, which would mean the
            # fileinfo record shouldn't be republished.
            next if !MT->model('template')->exist({
                    id      => $fi->template_id,
                    blog_id => $blog_id,
                    type    => { not => 'backup' },
                });

            # Create a Schwartz job for each file that needs to be published.
            PubOffline::Plugin::_create_publish_job({
                fileinfo  => $fi,
                jumpstart => 1,
            });
        }

        return $plugin->load_tmpl( 'dialog/close.tmpl' );
    }

    $param->{blog_id} = $blog_id;

    return $plugin->load_tmpl( 'dialog/jumpstart.tmpl', $param );
}

# Add the Publish Offline menu option, but only if PubOffline is enabled on
# this blog.
sub menus {
    return {
        'manage:puboffline' => {
            label       => 'Offline Archives',
            order       => 10000,
            mode        => 'po_manage',
            view        => 'blog',
            condition   => sub {
                my $blog = MT->instance->blog;
                return 0 if !$blog; # PubOffline only works at the blog level.

                # Check if PubOffline has been enabled on this blog.
                my $plugin = MT->component('PubOffline');
                return 0 if !$plugin; # No plugin found?
                # Returns 1 if enabled on this blog.
                return $plugin->get_config_value(
                    'enable_puboffline',
                    'blog:' . $blog->id
                );
                return 0;
            },
        },
    };
}

# What you see after picking the Offline Archives menu option.
sub manage {
    my $app     = shift;
    my ($param) = @_;
    my $q       = $app->param;
    my $blog_id = $app->blog->id;
    my $plugin  = MT->component('PubOffline');

    return $plugin->translate("Permission denied.")
        unless $app->user->is_superuser()
            || $app->user->permissions($blog_id)->can_administer_blog();

    # If PubOffline is not enabled for this blog, redirect to the Dashboard.
    # This might happen when switching from one blog to another.
    $app->redirect( $app->uri . '?__mode=dashboard&blog_id=' . $blog_id )
        if !$plugin->get_config_value(
            'enable_puboffline',
            'blog:' . $blog_id
        );;

    # Show any set system mesages.
    $param->{create_archive}  = $q->param('create_archive');
    $param->{deleted_archives} = $q->param('deleted_archives');
    $param->{failed_delete}   = $q->param('failed_delete');

    # Are there any Schwartz jobs for the offline site in queue? If so, we
    # should notify the user so that they can understand what's happening
    # at the moment.
    my @funcmap = MT->model('ts_funcmap')->load({
        funcname => [
            'PubOffline::Worker::HandleAsset',
            'PubOffline::Worker::HandleStatic',
            'PubOffline::Worker::PublishOffline',
        ],
    });
    my @funcmap_ids = map { $_->funcid } @funcmap;
    # Grab a count of how many Publish Offline related jobs there are. (Don't
    # count any offline archive jobs, because we report those separately.)
    $param->{po_jobs} = MT->model('ts_job')->count({
        funcid   => \@funcmap_ids,
        coalesce => { like => $blog_id.':%' }, # In the current blog only
    });

    # Are there any offline archives in the process of being built?
    my $funcmap = MT->model('ts_funcmap')->load({
        funcname => 'PubOffline::Worker::OfflineArchive',
    });
    $param->{po_archive_jobs} = MT->model('ts_job')->count({
        funcid   => $funcmap->funcid,
        coalesce => { like => $blog_id.':%' }, # In the current blog only
    });

    # Are any of the jobs in the queue Jumpstarts? We want to warn the user
    # that until the Jumpstart finishes the offline version is incomplete.
    $param->{jumpstart_in_process} = MT->model('ts_job')->exist({
        arg      => 'jumpstart',
        coalesce => { like => $blog_id.':%' }, # In the current blog only
    });

    $param->{output_file_path} = get_output_path({ blog_id => $blog_id });
    $param->{output_file_url}  = get_output_url({ blog_id => $blog_id });

    # Read the offline folder to see what archives are available, and use that
    # information to populate the listing screen.
    my @offline_archives;
    my $archive_path = get_archive_path({ blog_id => $blog_id });

    # Only try loading archives if an archive path was specified.
    if ($archive_path) {
        opendir (DIR, $archive_path);
        while ( my $file_name = readdir(DIR) ) {
            # Ignore anything except .zip files.
            next if $file_name !~ /\.zip$/;

            my $file_path = File::Spec->catfile($archive_path, $file_name);

            # Look at the last-modified time of the zip file. If it was last
            # modified more than about five seconds ago it's safe to guess
            # that the system has finished writing the file, so it can be
            # shown in the listing.
            next if -M $file_path < 0.00005;

            # Get the size of the zip file and turn it into something human-
            # readable.
            my $size = (stat $file_path)[7];
            # ...and make it human readable
            my @units = ('bytes','kB','MB','GB'); # Valid units
            my $u = 0;
            # If bigger than 1024 in the current unit, then jump to the next
            # unit larger. 1028 kB becomes 1 MB, for example.
            while ($size > 1024) {
                $size /= 1024;
                $u++;
            }
            $size = sprintf("%.2f", $size) . ' ' . $units[$u];

            # Get the date/timestamp of the file.
            my $epoch = (stat $file_path)[9]; # The file's modified-on date
            my @months = ("Jan","Feb","Mar","Apr","May","Jun","Jul","Aug",
                "Sep","Oct","Nov","Dec");
            my ($sec, $min, $hour, $day, $month, $year) 
                = (localtime($epoch))[0,1,2,3,4,5];
            my $period = 'AM'; # If $hour < 12, this is already correct.
            if ($hour >= 12) {
                $period = 'PM';
                $hour -= 12
                    if $hour != 12;
            }
            # Assemble a human-readable date.
            my $date = $months[$month] . ' ' . $day . ', ' . ($year+1900) 
                . ' ' . $hour . ":" . sprintf("%02d", $min) . ' ' . $period;

            push @offline_archives, {
                file_path => $file_path,
                file_name => $file_name,
                size      => $size,
                date      => $date,
                epoch     => $epoch, # Use this to sort, below.
            };
        }
    }

    # Sort the offline archives by date, so the newest archive is first. Use
    # the epoch to sort, since that won't rely upon things like leading zeroes.
    @offline_archives = sort { $b->{epoch} <=> $a->{epoch} } @offline_archives;

    $param->{offline_archives} = \@offline_archives;

    return $plugin->load_tmpl( 'manage.tmpl', $param );
}

# On the Manage > Offline Archives screen you can choose to create an archive.
sub create_archive {
    my $app     = shift;
    my ($param) = @_;
    my $q       = $app->query;
    my $blog_id = $q->param('blog_id');
    my $plugin  = MT->component('PubOffline');

    # If the user has clicked "Create Archive" button, start the process.
    # Build a Schwartz job, which will be responsible for creating the zip.
    if ( $q->param('create_archive') ) {
        # Ok, let's build the Schwartz Job.
        require MT::TheSchwartz;
        my $ts = MT::TheSchwartz->instance();

        my $priority = '10';

        my $func_id = $ts->funcname_to_id(
            $ts->driver_for,
            $ts->shuffled_databases,
            'PubOffline::Worker::OfflineArchive'
        );

        # Look for a job that has these parameters.
        my $job = MT->model('ts_job')->load({
            funcid  => $func_id,
            uniqkey => $blog_id,
        });

        unless ($job) {
            $job = MT->model('ts_job')->new();
            $job->funcid( $func_id );
            $job->uniqkey( $blog_id );
        }

        # If this job was previously sen to the queue then it already has an
        # email address specified. We want to keep that, and add this new one.
        my @existing = split(/\s*,\s*/, $job->arg); # Existing addresses
        my %emails = map { $_ => 1 } @existing; # Push array into a hash
        # Newly-entered emails should be parsed and added to the hash, too.
        foreach my $email ( split(/\s*,\s*/, $q->param('email')) ) {
            $emails{ $email }++;
        }
        # Now that we've got a hash of all email addresses, we can create a
        # simple string of all of them to be saved.
        my $email_string = join(',', keys %emails);
        $job->arg( $email_string );

        $job->priority( $priority );
        $job->grabbed_until(1);
        $job->run_after(1);
        $job->coalesce( 
            $blog_id
            . ':' . $$ 
            . ':' . $priority 
            . ':' . ( time - ( time % 10 ) ) 
        );

        $job->save or MT->log({
            blog_id => $blog_id,
            level   => MT::Log::ERROR(),
            message => "Could not queue Publish Offline archive job: " 
                . $job->errstr
        });

        $param->{redirect} = $app->mt_uri 
            . "?__mode=po_manage&blog_id=$blog_id&create_archive=1";
        return $plugin->load_tmpl( 'dialog/close.tmpl', $param );
    }

    $param->{offline_archives_path} = get_archive_path({ blog_id => $blog_id });
    $param->{default_email}         = $app->user->email;

    return $plugin->load_tmpl( 'dialog/create_archive.tmpl', $param );
}

# The user has clicked an archive to download -- return it to them.
sub download_archive {
    my $app     = shift;
    my ($param) = @_;
    my $q       = $app->query;
    my $file    = $q->param('file');

    # Disable client-side caching of this file and set headers so that the
    # file will be downloaded properly.
    $app->set_header( Pragma => 'no-cache' );

    unless ( ( $app->query->http('User-Agent') || '' ) =~ m{\bMSIE\b} ) {
        # The following have been said to not play well with IE
        $app->set_header( Expires => 0 );
        $app->set_header(
            Cache_Control => 'must-revalidate, post-check=0, pre-check=0' );
    }

    # Grab the filename so that the download starts with the proper name.
    my $filename = $file;
    $filename =~ s/.*\/(.*)$/$1/;

    # This forces the file download for **all** files (html, txt, images, etc)
    $app->set_header(
          Content_Disposition => 'attachment; filename="' . $filename . '"' );

    require HTTP::Date;
    my ( $size, $mtime ) = ( stat( $file ) )[ 7, 9 ];
    $app->set_header( 'Content-Length' => $size );
    $app->set_header( 'Last-Modified'  => HTTP::Date::time2str($mtime) )
        if $mtime;

    $app->response_content_type('application/zip');

    # Send the finalized headers to the client prior to the content
    $app->send_http_header();

    # Get a filehandle for the file so that the file contents can be streamed.
    use FileHandle;
    my $fh = FileHandle->new("< $file");

    # Reset the file pointer
    seek( $fh, 0, 0 );

    # Stream the file to the user's browser in chunks.
    while ( read( $fh, my $buffer, 8192 ) ) {
        $app->print($buffer);
    }

    $app->print('');    # print a null string at the end
    close($fh);

    return;
}

# The use is trying to delete one or more archives from the Manage Offline
# Archives listing screen.
sub delete_archive {
    my $app = MT->instance;
    my @files = $app->param('id');
    my $result;

    foreach my $file (@files) {
        if (-e $file) { # Be sure the file exists first.
            $result = unlink $file; # Delete it!

            if ($result) {
                MT->log({
                    blog_id   => $app->blog->id,
                    author_id => $app->user->id,
                    level     => MT->model('log')->INFO(),
                    message   => "The offline archive $file has been deleted.",
                });

                $result = 'deleted_archives=1'; # Show the system message
            }
            # The file couldn't be deleted.
            else {
                MT->log({
                    blog_id   => $app->blog->id,
                    author_id => $app->user->id,
                    level     => MT->model('log')->INFO(),
                    message   => "The offline archive $file could not be "
                        . "deleted. $!",
                });

                # Show the system message. Provide the error message, too.
                use URI::Escape;
                $result = 'failed_delete=' . uri_escape( $! );
            }
        }
    }

    # Go back to the Manage Offline Archives screen and report the result.
    $app->redirect(
        $app->mt_uri 
            . "?__mode=po_manage&blog_id=" . $app->blog->id . "&$result"
    );
}

1;

__END__
