package PubOffline::Plugin;

use strict;
use MT::Util qw( format_ts caturl dirify );

sub load_tasks {
    my $cfg = MT->config;
    return {
        'OfflineBatchCleanUp' => {
            'label' => 'Cleanup Finished Publish Batches',
            'frequency' => 1, #3 * 60,
            'code' => sub { 
                PubOffline::Plugin->task_cleanup; 
            }
        }
    };
}

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

sub tag_is_offline {
    my ( $ctx, $args, $cond ) = @_;
    my $bool = $ctx->stash('__offline_mode');
    return $bool ? 1 : 0;
}

#sub send_blogs_to_queue {
#    my $app = shift;
#    my ($param) = @_;
#    my $q       = $app->{query};
#    $param ||= {};
#    if ( $q->param('create_job') ) {
#        my @blog_ids = split(/,/, $q->param('blog_ids') );
#        foreach my $blog_id (@blog_ids) {
#            _create_batch( $blog_id, $q->param('email') );
#        }
#        return $app->load_tmpl( 'dialog/close.tmpl' );
#    }
#    $param->{blog_ids}       = join( ',', $q->param('id') );
#    $param->{default_email} = $app->user->email;
#    return $app->load_tmpl( 'dialog/send_to_queue.tmpl', $param );
#}

sub send_to_queue {
    my $app = shift;
    my ($param) = @_;
    my $q       = $app->{query};
    $param ||= {};

    return unless $app->blog;

    my $plugin = MT->component('PubOffline');

    if ($q->param('create_job')) {
        if (!-e $q->param('file_path') || !-d $q->param('file_path')) {
            $param->{path_nonexist} = 1;
        } elsif (!-w $q->param('file_path')) {
            $param->{path_unwritable} = 1;
        } else {
            # Save the Output File Path, Ouptut URL and Zip field settings
            # so that they can be re-used in the template, below.
            $plugin->set_config_value(
                'output_file_path', 
                $q->param('file_path'), 
                'blog:'.$app->blog->id
            );
            $plugin->set_config_value(
                'output_url', 
                $q->param('output_url'), 
                'blog:'.$app->blog->id
            );
            $plugin->set_config_value(
                'zip', 
                $q->param('zip') || '0', # If unchecked, record "0"
                'blog:'.$app->blog->id
            );
            $plugin->set_config_value(
                'date', 
                $q->param('date') || '0', # If unchecked, record "0"
                'blog:'.$app->blog->id
            );
            
            _create_batch( 
                $app->blog->id, 
                $q->param('email'), 
                $q->param('file_path'), 
            );
            return $app->load_tmpl( 'dialog/close.tmpl' );
        }
    }
    
    # If the user entered a new path or an unwritable path, that new result
    # should be returned to them. Otherwise, we want to return the saved path
    # and URL because that is most likely what the user wants to use again.
    $param->{file_path} = $q->param('file_path') 
                            || $plugin->get_config_value(
                                    'output_file_path', 
                                    'blog:'.$app->blog->id);
    $param->{output_url} = $q->param('output_url')
                            || $plugin->get_config_value(
                                    'output_url', 
                                    'blog:'.$app->blog->id);
    $param->{zip} = $q->param('zip')
                            || $plugin->get_config_value(
                                    'zip', 
                                    'blog:'.$app->blog->id);
    $param->{date} = $q->param('date')
                            || $plugin->get_config_value(
                                    'date', 
                                    'blog:'.$app->blog->id);
    # Only show the zip option if Archive::Zip is available.
    $param->{archive_zip_installed} =  eval "require Archive::Zip;" ? 1 : 0;
    $param->{batch_exists}  = MT->model('offline_batch')->exist(
                                    { blog_id => $app->blog->id }
                                );
    $param->{blog_id}       = $app->blog->id;
    $param->{default_email} = $app->user->email;
    return $app->load_tmpl( 'dialog/send_to_queue.tmpl', $param );
}

sub _create_batch {
    my ($blog_id, $email, $path) = @_;
    my $app = MT->instance;

    # Skip this blog if it's already marked to republish.
    return if ( MT->model('offline_batch')->exist({ blog_id => $blog_id }) );


    my $batch = MT->model('offline_batch')->new;
    $batch->blog_id( $blog_id );
    $batch->email( $email );
    #$batch->path( $path );
    $batch->save
        or return $app->error(
            $app->translate(
                "Unable to create a offline publishing batch and send "
                . "content to the publish queue",
                $batch->errstr
            )
        );

    # Now that the batch has been saved, we can grab the created_on time
    # and use that to build a path.
    my $date = '';
    if ( $app->param('date') ) {
        # Prepend an underscore as a separator
        $date = '_' . format_ts( 
            "%Y%m%d_%H%M%S", 
            $batch->created_on, 
            $batch->blog, 
            undef 
        );
    }
    if ( $app->param('zip') ) {
        # If a zip is needed, include a subdir of the blog name.
        $path = File::Spec->catfile(
            $path, 
            dirify($app->blog->name).$date,
            dirify($app->blog->name),
        );
    }
    else {
        $path = File::Spec->catfile(
            $path, 
            dirify($app->blog->name).$date,
        );
    }
    # Finally, save the $path, which includes a dated folder, if requested.
    $batch->path( $path );
    $batch->save;
    

    require MT::Request;
    my $r = MT::Request->instance();
    $r->stash('offline_batch',$batch);

    require MT::WeblogPublisher;
    my $pub = MT::WeblogPublisher->new;
    $pub->rebuild( BlogID => $blog_id );
    _create_copy_static_job( $batch );
    
    # Save the "real" blog site path so that it can be used later to copy
    # the assets.
    use MT::Session;
    my $session = MT::Session->new;
    $session->id('PubOffline blog '.$blog_id);
    $session->kind('po');
    my $blog = MT->model('blog')->load($blog_id);
    $session->data( $blog->site_path );
    $session->start(time());
    $session->save;
}

# This is invoked just before the file is written. We use this to re-write
# all URLs to map http://... to file://...
sub build_page {
    my ( $cb, %args ) = @_;
    my $fi = $args{'file_info'};
    if ($fi->{'offline_batch'}) {
        # Time to override the Blog's site path to the user specified site path
        my $batch   = $fi->{'offline_batch'};
        my $target  = $batch->path;
        $target = $target . '/' if $target !~ /\/$/;
        my $pattern = $fi->{'__original_site_url'};
        my $content = $args{'Content'};

        # The real blog site path was saved previously; grab it!
        use MT::Session;
        my $session = MT::Session::get_unexpired_value(
            86400, 
            { id   => 'Puboffline blog '.$batch->blog_id, 
              kind => 'po' }
        );
        my $blog_site_path = $session->data;
        $blog_site_path = $blog_site_path . '/' if $blog_site_path !~ /\/$/;

        # First determine if the current file is at the root of the blog
        my $file_path = $fi->file_path;
        $file_path =~ s/$target//;
        my ($vol, $dirs_path, $file) = File::Spec->splitpath($file_path);
        my @dirs = File::Spec->splitdir( $dirs_path );

        if ( scalar @dirs >= 1 ) {
            #MT->log("$file_path is in a directory: $dirs_path.");
            # If the file is not at the root, (that is, there were directories
            # found) we need to determine how many folders up we need to go to
            # get back to the root of the blog.
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
                unshift @dirs, '..';
                my $new_dirs_path = File::Spec->catdir( @dirs );
                my $path = caturl($new_dirs_path, $file);
                $path . $quote;
            }emgx;
        }
        else {
            #MT->log("$file_path is at the root.");
            # If the file is at the root, we just need to generate a simple
            # relative URL that doesn't need to traverse up a folder at all.
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

        # Static content may be specified with StaticWebPath or
        # PluginStaticWebPath, so we need to fix those URLs, too.
        require MT::Template::ContextHandlers;
        my $static_pattern = MT::Template::Context::_hdlr_static_path( $args{'Context'} );
        if ( scalar @dirs >= 1 ) {
            # If the file is not at the root, (that is, there were directories
            # found) we need to determine how many folders up we need to go to
            # get back to the root of the blog.
            $$content =~ s{$static_pattern(.*?)("|'|\))}{
                ($vol, $dirs_path, $file) = File::Spec->splitpath($1);
                @dirs = File::Spec->splitdir( $dirs_path );
                unshift @dirs, 'static';
                unshift @dirs, '..';
                my $new_dirs_path = File::Spec->catdir( @dirs );
                my $path = caturl($new_dirs_path, $file);
                $path . $2;
            }emgx;
        }
        else {
            # If the file is at the root, we just need to generate a simple
            # relative URL that doesn't need to traverse up a folder at all.
            $$content =~ s{$static_pattern(.*?)("|'|\))}{
                # abs2rel will convert the path to something relative.
                # $2 is the single or double quote to be included.
                File::Spec->abs2rel( 'static/'.$1 ) . $2;
            }emgx;
        }

        # The CGIPath is used in mt.js, and may be used for commenting forms,
        # for example. Changing those to relative URLs doesn't really matter
        # because it'll point to something that doesn't work: mt-comments.cgi,
        # for example, isn't copied offline, and even if it was it won't work
        # because it's not set up!
    }
}

# Adds every non-disabled template to the publish queue. 
# This is a near copy of the build_file_filter in MT::WeblogPublisher
sub build_file_filter {
    my ( $cb, %args ) = @_;
    my $fi = $args{'file_info'};

    # Prevents requeuing. In other words it tells the Worker making a call to
    # this filter that the decision to publish this file via the publish queue
    # has already been made. Therefore we need to short circuit this callback.
    # This is our opportunity therefore to modify the template context before
    # returning!
    if ($fi->{'offline_batch'}) {
        # Time to override the Blog's site path to the user specified site path
        my $batch = $fi->{'offline_batch'};
        my $url   = $args{'Blog'}->site_url;
        $args{'file_info'}->{'__original_site_url'} = $url;
        $args{'Blog'}->site_path($batch->path);
        $args{'Context'}->stash('__offline_mode',1);
        MT->log({
            blog_id => $args{'Blog'}->id,
            message => 'Publishing file to: '.$args{'File'},
        });
        # Return 1 and tell MT to physically publish the file!
        return 1;
    }

    # We are obviously not coming from the MT::Worker::PublishOffline 
    # task. We know this of course because $fi->{offline_batch} will
    # be set otherwise.
    require MT::Request;
    my $r = MT::Request->instance();
    my $batch = $r->stash('offline_batch');
    unless ($batch) {
        # Batch does not exist, so assume we can publish. Let other 
        # build_file_filters determine course of action.
        return 1;
    }

    require MT::PublishOption;
    my $throttle = MT::PublishOption::get_throttle($fi);

    # Prevent building of disabled templates if they get this far
    return 0 if $throttle->{type} == MT::PublishOption::DISABLED();

    _create_publish_job( $fi, $batch );
    return 0;
}

sub _create_publish_job {
    my ($fi,$batch) = @_;

    # Ok, let's build the Schwartz Job.
    require MT::TheSchwartz;
    my $ts = MT::TheSchwartz->instance();
    my $priority = _get_job_priority($fi);
    my $func_id = $ts->funcname_to_id($ts->driver_for,
                                      $ts->shuffled_databases,
                                      'MT::Worker::PublishOffline');
    my $job = MT->model('ts_job')->new();
    $job->funcid( $func_id );
    $job->uniqkey( $fi->id );
    $job->offline_batch_id( $batch->id );
    $job->priority( $priority );
    $job->grabbed_until(1);
    $job->run_after(1);
    $job->coalesce( ( $fi->blog_id || 0 ) . ':' . $$ . ':' . $priority . ':' . ( time - ( time % 10 ) ) );
    $job->save or MT->log({
        blog_id => $fi->blog_id,
        message => "PubOffline: could not queue offline publish job: " . $job->errstr
    });
}

sub _create_copy_static_job {
    my ($batch) = @_;

    # Ok, let's build the Schwartz Job.
    require MT::TheSchwartz;
    my $ts = MT::TheSchwartz->instance();
    my $func_id = $ts->funcname_to_id($ts->driver_for,
                                      $ts->shuffled_databases,
                                      'MT::Worker::CopyStaticOffline');
    my $job = MT->model('ts_job')->new();
    $job->funcid( $func_id );
    $job->uniqkey( $batch->id );
    $job->offline_batch_id( $batch->id );
    $job->priority( 9 );
    $job->grabbed_until(1);
    $job->run_after(1);
    $job->coalesce( ( $batch->blog_id || 0 ) . ':' . $$ . ':' . 9 . ':' . ( time - ( time % 10 ) ) );
    $job->save or MT->log({
        blog_id => $batch->blog_id,
        message => "PubOffline: could not queue copy static job: " . $job->errstr
    });
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

1;
__END__
