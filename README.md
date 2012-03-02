# Publish Offline Overview

Publish Offline is a plugin for Movable Type and Melody that adds the ability
to publish a blog to an alternate directory, in addition to the Blog Site Path
where the blog is already published. It will automatically publish the entire
blog to that directory (including assets and any static files you've
specified), and before writing files to the target directory will rewrite all
URLs as relative -- creating a site that can be browsed offline or locally,
for example.

On a configured blog, Publish Offline is constantly monitoring for changes, to
keep the offline version of the blog up-to-date. When an entry is edited and
republished, for example, Publish Offline notices and also queues any
necessary templates to be republished at the specified offline location.

In addition to creating an offline version, Publish Offline provides the
ability to create a snapshot of the offline version by creating a zip archive.
An archive management interface is also included.


# Prerequisites

* Movable Type 4.x
* PubOffline makes use of the Publish Queue. You'll therefore need a way to
  run the Publish Queue, most likely with `run-periodic-tasks`.
* [Melody Compatibility Pack](https://github.com/endevver/mt-plugin-melody-compat/downloads)


# Installation

To install this plugin follow the instructions found here:

http://tinyurl.com/easy-plugin-install


# Configuration

Publish Offline needs to be set up for each blog you want to use it with. From
the navigation menu choose Tools > Plugins, find Publish Offline, and review
the Settings.

* Enable Publish Offline - enable or disable Publish Offline for this blog.

* Offline Output File Path - this is the path to which Publish Offline will
  output the offline version of this blog. This should be an absolute file
  path; MT tags are allowed, though BlogSitePath is likely the only tag you
  would use.

* Offline Output File URL - this is the URL that the offline version is
  available at. If the Output File Path specified above is outside of the web
  root and is therefore not available at a URL, this field should be empty. If
  filled in, this field should contain a fully-qualified domain name; MT tags
  are allowed, though BlogURL is likely the only tag you would use.

* Offline Archives File Path - this is the path to which Publish Offline will
  the zip archives of the offline version of this blog. This should be an
  absolute file path; MT tags are allowed, though BlogSitePath is likely the
  only tag you would use.

* Try to use Root Relative URLs - the Blog URL and Static Web Path are used to
  create relative links within the offline files. If you specify root relative
  URLs within entries (that is, URLs without the protocol or domain) then you
  probably want to enable this feature. Note that this feature is experimental
  in that if your URL is not unique enough to be identified as a root relative
  URL, you may see unexpected results in the links created for the offline
  files.

  Example: your Blog URL is `http://example.com/my-awesome-blog/` and you use
  root relative URLs in Entries (such as `/my-awesome-blog/photo-of-me.jpg`).
  Enabling this feature will use the root relative URL `/my-awesome-blog/` in
  addition to the Blog URL `http://example.com/my-awesome-blog/` when creating
  the relative URLs used in the offline version. `/my-awesome-blog/` is unique
  enough for this to work well.

  Example: your Blog URL is `http://example.com/` and you use root relative
  URLs in Entries (such as `/photo-of-me.jpg`). Enabling this feature will use
  the root relative URL `/` in addition to the Blog URL `http://example.com/`
  when creating the relative URLs used in the offline version. `/` is not
  unique and relative URLs will not be correctly created; this feature should
  not be used here.

* Asset Handling - assets in this blog can be copied to the Offline Output
  File Path, or hard links to the assets can be created. Hard links have the
  benefit of saving disk space and always being up-to-date, though they won't
  work with a Windows-based server. Copying is safe and always works.

* Static File Handling - Movable Type's static content is sometimes required
  for a theme or for assets handled by the system, for example. If the static
  files are needed, you'll want them in the offline version of this blog, too.
  Static files can be copied to the Offline Output File Path, or hard links to
  the files can be created.

* Static File Manifest - if static files should be copied offline, a manifest
  can help ensure that only the pertinent files are copied or hard linked.
  Leave this textarea empty to copy/link all static content. Alternatively,
  specify an absolute path to a file or folder. Specify additional files or
  folders on separate lines. The template tag StaticFilePath can be helpful in
  specifying content you want in the offline version.

* Exclude File Manifest - their may be some files you don't want copied to the
  offline version (such as some index Templates, Entries, or Pages). Leave
  this textarea empty to copy all content offline. Alternatively, specify
  files to exclude with a path relative to the Offline Output File Path,
  specified above. Each exclude file path should be on a new line.

* URL Exception Manifest - their may be some URLs you don't want rewritten for
  the offline version. (That is, you want the URL to go to the same
  fully-qualified domain name whether part of the Offline version or not.)
  Leave this textarea empty to rewrite all URLs. Alternatively, specify
  fully-qualified domain name URLs to *not* be rewritten, one per line.

* Jumpstart this Blog - an asset will be automatically copied or linked when
  the asset has been modified. However existing assets need a "jumpstart" to
  become part of the offline version. Similarly, static content will be copied
  during an upgrade but existing content needs a "jumpstart" to become part of
  the offline version. The jumpstart will also publish templates offline.
  Click the button to Jumpstart this blog.


# Template Tags

The plugin also defines the following template tag:

    <mt:IsOfflineMode><mt:Else></mt:IsOfflineMode>

This template tag can be used to output templates differently when publishing
for offline distribution.


# Usage

First you'll want to work the configuration options, of course. If you haven't
started a Jumpstart, do it now to get the offline location populated.

As noted in the overview, Publish Offline will automatically work in the
background to keep the offline version of a blog updated. Whenever a template
is republished for the live blog, it's also queued to be published at the
offline location. Similarly, when an asset is uploaded or edited, it's queued
to be copied or linked to the offline location. After the initial
configuration, Publish Offline will just do all of the work for you!

> Note that there is a delay between when something is done on the live blog
> and when it appears in the offline location. Items are queued for the
> offline version when they are made live on the normal online version. The
> queue is managed by the frequency `run-periodic-tasks` executes on, which
> also handles other publishing and maintenance duties. duties. If
> `run-periodic-tasks` is running on a 15 minute schedule, it's safe to assume
> that the offline version will be about 15 minutes behind the live site's
> updates.

Visit Manage > Offline Archives to manage archives of the offline version, as
well as for a little insight to the offline blog's status. What you'll find on
Manage Offline Archives:

* Notification of a Jumpstart in process.
* Notification of any offline archive jobs in the queue.
* Notification of any offline publishing jobs in the queue.
* Ability to take a snapshot of the offline location, saving as a zip archive.
* Ability to manage the offline archives.

The management interface uses the familiar listing screen, so any
administrator should be familiar with how to use it. Archives can be
downloaded and deleted from this interface.

Offline archives are created by clicking the Create an Offline Archive button
found on the Manage Offline Archives interface. A popup dialog will appear --
simply click Create Archive to get started. This will be added to the queue;
specify email addresses for notification of when the archive is available.


# About Endevver

We design and develop web sites, products and services with a focus on 
simplicity, sound design, ease of use and community. We specialize in 
Movable Type and offer numerous services and packages to help customers 
make the most of this powerful publishing platform.

http://www.endevver.com/

# Support

For help with this plugin please visit http://help.endevver.com

# Copyright

Copyright 2010-2011, Endevver, LLC. All rights reserved.

# License

This plugin is licensed under the same terms as Perl itself.
