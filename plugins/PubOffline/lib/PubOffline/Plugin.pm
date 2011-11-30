package PubOffline::Plugin;

use strict;
use MT::Util qw( format_ts caturl dirify );
use PubOffline::Util qw( get_output_path render_template );

sub task_cleanup {
    my $this = shift;
    require MT::Util;
    my $mt = MT->instance;
    my @batches = MT->model('offline_batch')->load();
    foreach my $batch (@batches) {
        if (MT->model('ts_job')->exist( { offline_batch_id => $batch->id } )) {
            # do nothing at this time
            # possible future: see how long the job has been on the queue,
            # send warning if it has been on the queue too long
        } else {
            my $plugin = MT->component('PubOffline');
            my $zip_pref = $plugin->get_config_value('zip', 'blog:'.$batch->blog_id);
            my $zip_message = '';
            if ($zip_pref) {
                # The $zip_message contains both a success and fail notice.
                $zip_message = _zip_offline($batch);
            }
            # Notify the specified user that we're done
            if ($batch->email) {
                MT->log({ 
                    message => "It appears the offline publishing batch "
                        . "with an ID of " .$batch->id. " has finished. "
                        . "Notifying " . $batch->email . " and cleaning up.",
                    class   => "system",
                    blog_id => $batch->blog->id,
                    level   => MT::Log::INFO()
                });
                my $date = format_ts( 
                    "%Y-%m-%d at %H:%M:%S", 
                    $batch->created_on, 
                    $batch->blog, 
                    undef 
                );

                # Grab the Output URL, if supplied. This way we can provide
                # a web-accessible link to the offline version, so the user
                # can easily check out the result.
                my $output_url = $plugin->get_config_value(
                    'output_url', 
                    'blog:'.$batch->blog_id
                );
                # If a URL was provided and a zip archive was created, we 
                # want to supply an output URL that correctly points to the 
                # sub-folder with the offline site.
                if ($output_url) {
                    # Add a trailing slash if there isn't already one.
                    $output_url .= '/' unless $output_url =~ m!/$!;
                    # Prepend an underscore as a separator
                    my $folder_date = '';
                    if ( $plugin->get_config_value('date', 'blog:'.$batch->blog_id) ) {
                        $folder_date = '_' . format_ts( 
                            "%Y%m%d_%H%M%S", 
                            $batch->created_on, 
                            $batch->blog, 
                            undef 
                        );
                    }
                    my $blog_name = dirify($batch->blog->name);
                    # The output URL needs to be handled specially depending
                    # on if a zip was requested.
                    if ($zip_pref) {
                        # Assemble the subdirectory name.
                        $output_url .= $blog_name.$folder_date.'/'.$blog_name;
                        # Include a note about the zip in the email.
                        if ($zip_message) {
                            # Zip archive successfully created
                            $zip_message = "Download the zip archive of the offline version at:\n\n"
                                . $output_url . "_offline.zip\n\n";
                        }
                        else {
                            # Zipping failed
                            $zip_message = "The zip archive could not be "
                                . "written to " . $batch->path . $blog_name
                                . "_offline.zip. Check permissions before "
                                . "trying again.\n\n";
                        }
                    }
                    else {
                        # A zip file was not needed.
                        $output_url .= $blog_name.$folder_date,
                    }
                }
                else {
                    # No URL was provided, so just return the file path.
                    $output_url = $batch->path;
                }

                require MT::Mail;
                my %head = ( 
                    To      => $batch->email, 
                    Subject => '[' . $batch->blog->name 
                        . '] Offline Publishing Batch Finished',
                );
                my $body = "The offline publishing batch you initiated on "
                    . "$date has completed.\n\n"
                    . "View the offline version in a web browser at:\n\n"
                    . $output_url . "\n\n" . $zip_message;
                MT::Mail->send(\%head, $body)
                    or die MT::Mail->errstr;
            } else {
                MT->log({
                    message => "It appears the offline publishing batch "
                        . "with an ID of " .$batch->id. " has finished. "
                        . "Cleaning up.",
                    class   => "system",
                    blog_id => $batch->blog->id,
                    level   => MT::Log::INFO()
                });
            }
            # TODO - copy static files
            $batch->remove;
        }
    }
}

sub _zip_offline {
    my ($batch) = @_;
    # Zip the offline content. Note that the $batch->path is set 
    # to the user-supplied Output File Path plus the dirified 
    # blog name. That way, the offline version and the zip will
    # exist at the user-specified Output File Path location.
    use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
    my $zip = Archive::Zip->new();

    my $blog = MT->model('blog')->load($batch->blog_id);
    my $blog_name = dirify($blog->name);

    # Add the offline version and all files to the zip. Replace
    # the big long path with simply $blog_name.'_offline' so that
    # it can easily be extracted into a directory.
    $zip->addTree( $batch->path, $blog_name.'_offline' );

    # Go up a directory. The dirified blog name was previously
    # appended to the Output File Path, so we know that is at the
    # end of the saved path.
    my $parent_dir = $batch->path;
    $parent_dir =~ s/^(.*)$blog_name/$1/;

    # Craft the zip destination URL
    my $zip_dest   = File::Spec->catfile(
        $parent_dir, 
        $blog_name.'_offline.zip'
    );

    # Delete any old archive before writing the new one.
    unlink($zip_dest);

    # Finally, write the zip file to disk.
    if ( $zip->writeToFileNamed($zip_dest) == AZ_OK ) {
        # Success!
        MT->log({ 
            message => "The offline publishing batch with an ID of " 
                . $batch->id . " created a zip archive at $zip_dest.",
            class   => "system",
            blog_id => $batch->blog->id,
            level   => MT::Log::INFO()
        });
        return 1;
    }
    else {
        # Failed to write!
        MT->log({ 
            message => "The offline publishing batch with an ID of " 
                . $batch->id . " was unable to create a zip archive at "
                . "$zip_dest. (The offline site contents were successfully "
                . "created, but the zip archive was not successful.) Check "
                . "folder permissions before trying again.",
            class   => "system",
            blog_id => $batch->blog->id,
            level   => MT::Log::ERROR()
        });
        return 0;
    }
}

# Any time a template is published, it goes through the build_filter_filter.
# PubOffline works by hooking into this callback and publishing an additional
# copy of the file to the designated offline location. 
# This is a near copy of the build_file_filter in MT::WeblogPublisher
sub build_file_filter {
    my ( $cb, %args ) = @_;
    my $fi = $args{'file_info'};
    my $plugin = MT->component('PubOffline');

    # We want to give up if PubOffline was not enabled on this blog.
    my $enabled = $plugin->get_config_value(
        'enable_puboffline',
        'blog:' . $fi->blog_id
    );
    return 1 if !$enabled;

    # This first block of code checks to see if the file being republished is
    # coming from the PubOffline::Worker::PublishOffline worker. If it is,
    # then we know that we need to set the IsOfflineMode tag context to true
    # so that any offline templating publishing correctly.
    if ($fi->{'is_offline_file'}) {

        # This flag is used for the IsOfflineMode tag.
        $args{'Context'}->stash('__offline_mode', 1);

        # Return and tell MT to physically publish the file!
        return 1;
    }

    # Since we got this far, we know that the 
    # PubOffline::Worker::PublishOffline is not running this callback. That
    # means we want to be sure to create an offline counterpart for this job,
    # and that's what the below is reponsible for ensuring.
    
    require MT::PublishOption;
    my $throttle = MT::PublishOption::get_throttle($fi);

    # Prevent building of disabled templates if they get this far
    return if $throttle->{type} == MT::PublishOption::DISABLED();

    _create_publish_job( $fi );
}

sub _create_publish_job {
    my ($fi) = @_;

    # Ok, let's build the Schwartz Job.
    require MT::TheSchwartz;
    my $ts = MT::TheSchwartz->instance();
    my $priority = _get_job_priority($fi);
    my $func_id = $ts->funcname_to_id(
        $ts->driver_for,
        $ts->shuffled_databases,
        'PubOffline::Worker::PublishOffline'
    );

    # Look for a job that has these parameters.
    my $job = MT->model('ts_job')->load({
        funcid  => $func_id,
        uniqkey => $fi->id,
    });

    unless ($job) {
        $job = MT->model('ts_job')->new();
        $job->funcid( $func_id );
        $job->uniqkey( $fi->id );
    }

    $job->priority( $priority );
    $job->grabbed_until(1);
    $job->run_after(1);
    $job->coalesce( 
        ( $fi->blog_id || 0 ) 
        . ':' . $$ 
        . ':' . $priority 
        . ':' . ( time - ( time % 10 ) ) 
    );

    $job->save or MT->log({
        blog_id => $fi->blog_id,
        level   => MT::Log::ERROR(),
        message => "Could not queue offline publish job: " . $job->errstr
    });
}

# This is invoked just before the file is written. We use this to re-write
# all URLs to map http://... to file://...
sub build_page {
    my ( $cb, %args ) = @_;
    my $fi     = $args{'file_info'};
    my $blog   = $args{'blog'};
    my $plugin = MT->component('PubOffline');

    # We want to give up if PubOffline was not enabled on this blog.
    my $enabled = $plugin->get_config_value(
        'enable_puboffline',
        'blog:'.$blog->id
    );
    return if !$enabled;

    # Give up if this callback was *not* invoked for an offline publish job.
    # Basically, if not coming from PubOffline::Worker::PublishOffline, quit.
    return if !$fi->{'is_offline_file'};

    MT->log({
        blog_id => $blog->id,
        level   => MT::Log::INFO(),
        message => 'PubOffline is writing to: ' . $args{'File'},
    });

    my $blog_site_path = $blog->site_path;
    $blog_site_path = $blog_site_path . '/' if $blog_site_path !~ /\/$/;

    # Use the output file path to determine how many directories deep a URL
    # needs to point to create the relative link.
    my $output_file_path = get_output_path({ blog_id => $blog->id });

    # First determine if the current file is at the root of the blog by making
    # the file path relative. To do that, try stripping off the output file
    # path and the blog site path. (The output file path will be in use for
    # archive templates, while the blog site path will be used for index
    # templates.)
    my $file_path = $fi->file_path;
    $file_path =~ s/($output_file_path|$blog_site_path)//;

    my ($vol, $dirs_path, $file) = File::Spec->splitpath($file_path);
    my @dirs = File::Spec->splitdir( $dirs_path );

    # The voodoo below constructs the relative path back to the root from the
    # current file. This is used in building a path to static files, as well
    # as to other files in the web site/blog. Here is how it works. 
    # a) Take a string to the current file. This should have the http://host
    #    removed.
    # b) Extract the directories from that path.
    my @reldirs;
    my @dirs_to_file = File::Spec->splitdir( $file_path );
    my $filename = pop @dirs_to_file;
    # c) Replace each directory with a '..' (the relative equivalent)
    foreach (@dirs_to_file) { unshift @reldirs,'..'; }
    # By this point @reldirs holds the relative directory components back to the root

    # Content is the actual rendered page HTML. Search it for the $pattern to
    # create a relative directory.
    my $pattern = $blog->site_url;
    my $content = $args{'Content'};

    # Static content may be specified with StaticWebPath or
    # PluginStaticWebPath, so we need to fix those URLs. Do this before fixing
    # any other URL because StaticWebPath may be in the BlogURL, but different
    # from the default.
    require MT::Template::ContextHandlers;
    my ($static_pattern, $static_pattern_a, $static_pattern_b);
    $static_pattern_a = $static_pattern_b 
        = MT::Template::Context::_hdlr_static_path( $args{'Context'} );
    $static_pattern_b =~ s/^https?\:\/\/[^\/]*//i;
    $static_pattern = "($static_pattern_a|$static_pattern_b)";

    # If the file is not at the root, (that is, there were directories
    # found) we need to determine how many folders up we need to go to
    # get back to the root of the blog.
    if ( scalar @dirs >= 1 ) {
        # print STDERR "Static path needs to be made relative.\n";
        $$content =~ s{$static_pattern([^"'\)]*)(["'\)])}{
            my (undef, $static_dirs_path, $static_file) = File::Spec->splitpath($2);
            my @static_dirs = File::Spec->splitdir( $static_dirs_path );
            my $path = caturl(@reldirs, 'static', @static_dirs, $static_file);
            $path . $3;
        }emgx;
    }
    # If the file is at the root, we just need to generate a simple
    # relative URL that doesn't need to traverse up a folder at all.
    else {
        # print STDERR "File is at root\n";
        $$content =~ s{$static_pattern([^"'\)]*)}{
            # abs2rel will convert the path to something relative.
            # $2 is the single or double quote to be included.
            File::Spec->abs2rel( 'static/' . $2 );
        }emgx;
    }

    # Note: The CGIPath is used in mt.js, and may be used for commenting
    # forms,for example. Changing those to relative URLs doesn't really matter
    # because it'll point to something that doesn't work: mt-comments.cgi, for
    # example, isn't copied offline, and even if it was it won't work because
    # it's not set up!

    # If the file is not at the root, (that is, there were directories
    # found) we need to determine how many folders up we need to go to
    # get back to the root of the blog.
    if ( scalar @dirs >= 1 ) {
        #print STDERR "$file_path is in a directory: $dirs_path.\n";
        $$content =~ s{$pattern(.*?)("|')}{
            my $quote  = $2;
            my $target = $1;

            # Check if the target is a directory. Compare to the live
            # published site, because the offline destination may not have
            # been published yet.
            if ( -d $blog_site_path.$target ) {
                # This is a directory. We can't have a bare directory in
                # the offline version, because clicking a link to it will
                # just show the contents of the directory.
                # So, append "index.html"
                $target = $target . '/' if $target !~ /\/$/;
                $target .= 'index.html';
            }

            ($vol, $dirs_path, $file) = File::Spec->splitpath($target);
            @dirs = File::Spec->splitdir( $dirs_path );
            my $new_dirs_path = File::Spec->catdir( @reldirs, @dirs );
            my $path = caturl($new_dirs_path, $file);
            #print STDERR "Path will be $path\n";
            $path . $quote;
        }emgx;
    }
    # If the file is at the root, we just need to generate a simple
    # relative URL that doesn't need to traverse up a folder at all.
    else {
        #print STDERR "$file_path is at the root.\n";
        $$content =~ s{$pattern(.*?)("|')}{
            my $quote  = $2;
            my $target = $1;

            # Remove the leading slash, if present. Since this file is at
            # the root of the site, there should be no URLs starting with
            # a slash.
            $target =~ s/^\/(.*)$/$1/;

            # Check if the target is a directory. Compare to the live
            # published site, because the offline destination may not have
            # been published yet.
            if ( -d $blog_site_path.$target ) {
                # This is a directory. We can't have a bare directory in
                # the offline version, because clicking a link to it will
                # just show the contents of the directory.
                # So, append "index.html"
                if ($target ne '') {
                    # $target will equal '' if it's the blog URL. We don't
                    # want to prepend a slash for this. because it'll make
                    # File::Spec->abs2rel() create a funky URL.
                    $target = $target . '/' if $target !~ /\/$/;
                }
                $target .= 'index.html';
            }

            # abs2rel will convert the path to something relative.
            # $quote is the single or double quote to be included.
            File::Spec->abs2rel( $target ) . $quote;
        }emgx;
    }
}

sub _get_job_priority {
    my ($fi) = @_;
    my $priority = 0;
    my $at = $fi->archive_type || '';
    # Default priority assignment....
    if (($at eq 'Individual') || ($at eq 'Page')) {
        require MT::TemplateMap;
        my $map = MT::TemplateMap->load($fi->templatemap_id);
        # Individual/Page archive pages that are the 'permalink' pages
        # should have highest build priority.
        if ($map && $map->is_preferred) {
            $priority = 10;
        } else {
            $priority = 5;
        }
    } elsif ($at eq 'index') {
        # Index pages are second in priority, if they are named 'index'
        # or 'default'
        if ($fi->file_path =~ m!/(index|default|atom|feed)!i) {
            $priority = 9;
        } else {
            $priority = 8;
        }
    } elsif ($at =~ m/Category|Author/) {
        $priority = 1;
    } elsif ($at =~ m/Yearly/) {
        $priority = 1;
    } elsif ($at =~ m/Monthly/) {
        $priority = 2;
    } elsif ($at =~ m/Weekly/) {
        $priority = 3;
    } elsif ($at =~ m/Daily/) {
        $priority = 4;
    }
    return $priority;
}

# After saving an asset we want to be sure it gets copied offline.
sub cms_post_save_asset {
    my ($cb, $app, $asset, $original_asset) = @_;
    my $plugin = MT->component('PubOffline');

    # We want to give up if PubOffline was not enabled on this blog.
    my $enabled = $plugin->get_config_value(
        'enable_puboffline',
        'blog:' . $asset->blog_id
    );
    return if !$enabled;

    _create_asset_handling_job( $asset );
}

# When uploading a file, we want to be sure it gets copied offline.
sub cms_upload_file {
    my ($cb, %params) = @_;
    my $plugin = MT->component('PubOffline');

    # We want to give up if PubOffline was not enabled on this blog.
    my $enabled = $plugin->get_config_value(
        'enable_puboffline',
        'blog:' . $params{blog}
    );
    return if !$enabled;

    _create_asset_handling_job( $params{asset} );
}

# Create a The Schwartz job for an asset.
sub _create_asset_handling_job {
    my ($asset) = @_;

    # Ok, let's build the Schwartz Job.
    require MT::TheSchwartz;
    my $ts = MT::TheSchwartz->instance();

    my $func_id = $ts->funcname_to_id(
        $ts->driver_for,
        $ts->shuffled_databases,
        'PubOffline::Worker::HandleAsset'
    );

    # Look for a job that has these parameters.
    my $job = MT->model('ts_job')->load({
        funcid  => $func_id,
        uniqkey => $asset->id,
    });

    unless ($job) {
        $job = MT->model('ts_job')->new();
        $job->funcid( $func_id );
        $job->uniqkey( $asset->id );
    }

    my $priority = 10;

    $job->priority( $priority );
    $job->grabbed_until(1);
    $job->run_after(1);
    $job->coalesce( 
        ( $asset->blog_id || 0 ) 
        . ':' . $$ 
        . ':' . $priority 
        . ':' . ( time - ( time % 10 ) ) 
    );

    $job->save or MT->log({
        blog_id => $asset->blog_id,
        level   => MT::Log::ERROR(),
        message => "Could not queue Publish Offline asset handler: " 
            . $job->errstr,
    });
}

# Use the Static Manifest Field to decide what static content needs to be
# handled.
sub _create_static_handling_jobs {
    my $blog_id = @_;
    my $plugin = MT->component('PubOffline');

    # Just give up if static files are not required.
    my $static_handling = $plugin->get_config_value(
        'static_handling',
        'blog:' . $blog_id,
    );
    return if $static_handling eq 'none';

    # Grab the static manifest, which is used to determine what content is
    # needed.
    my $static_manifest = $plugin->get_config_value(
        'static_manifest',
        'blog:' . $blog_id,
    );

    if ($static_manifest) {
        # The manifest can contain many paths, each on their own line. Split
        # on the new line and put them into an array so they can be processed.
        # Also, chop off any leading or trailing white space.
        my @paths = split(/\s*[\r\n]\s*/, $static_manifest);

        foreach my $path (@paths) {
            # If a template tag was used in specifying the path we want to
            # render it before trying to use the path.
            $path = render_template({
                blog_id => $blog_id,
                text    => $path,
            });

            # Check that the path exists and give up if it doesn't.
            next if !-e $path;

            # Create a static handling job for this path.
            _create_static_handling_job({
                path    => $path,
                blog_id => $blog_id,
            });
        }
    }

    # No static manifest details were specified, which means we want all
    # static content to be copied or linked.
    else {
        my $static_file_path = MT->config('StaticFilePath');

        _create_static_handling_job({
            path    => $static_file_path,
            blog_id => $blog_id,
        });
    }
}

# Create a Schwartz job to copy or link the static content. If the Static File
# Manifest field was used, the user can specify what static content is needed
# and we can create a separate job for each of the items they specify, so
# multiple static handling jobs may be created.
sub _create_static_handling_job {
    my ($arg_ref) = @_;
    my $path    = $arg_ref->{path};
    my $blog_id = $arg_ref->{blog_id};

    # Ok, let's build the Schwartz Job.
    require MT::TheSchwartz;
    my $ts = MT::TheSchwartz->instance();
    my $func_id = $ts->funcname_to_id($ts->driver_for,
                                      $ts->shuffled_databases,
                                      'PubOffline::Worker::HandleStatic');


    # Look for a job that has these parameters.
    my $job = MT->model('ts_job')->load({
      funcid  => $func_id,
      uniqkey => $path,
    });

    unless ($job) {
      $job = MT->model('ts_job')->new();
      $job->funcid( $func_id );
      # The unique key is the path to the static files to be handled. This could
      # be the `<mt:StaticFilePath>`, or it could be a subdirectory or file,
      # such as `<mt:StaticFilePath/support/plugins/my-awesome-plugin/`.
      $job->uniqkey( $path );
    }

    $job->priority( 10 );
    $job->grabbed_until(1);
    $job->run_after(1);
    $job->coalesce( 
        $blog_id
        . ':' . $$ 
        . ':' . 10 
        . ':' 
        . ( time - ( time % 10 ) ) 
    );

    $job->save or MT->log({
        blog_id => $blog_id,
        level   => MT::Log::ERROR(),
        message => "Could not queue Publish Offline static handler: " 
            . $job->errstr,
    });
}

1;

__END__

