# Publish Offline Overview

This plugin allows for users to publish a site to an alternate directory. It will automatically publish the entire site to that directory, as well as all static files, and before writing files to the target directory rewrite all URLs as relative as opposed to `http://`--creating a site that can be browsed offline or locally, for example.

# Prerequisites

* Movable Type 4.x
* PubOffline makes use of the Publish Queue. You'll therefore need a way to run the Publish Queue, most likely with `run-periodic-tasks`.

# Installation

To install this plugin follow the instructions found here:

http://tinyurl.com/easy-plugin-install

# Usage

To publish a site for offline use, navigate to the List Templates screen. Then click "Publish Offline Version" in the page actions widget on the right hand side.

On the Create Offline Version screen you are presented with several fields to work with:

* Output File Path - This is the path where your files will be published, and should be an absolute path (starting with "`/`"). By default, this is your Blog Site Root with `/puboffline/` appended. The path you enter here will be saved for the next time you wish to publish offline.
* Output URL - This is a web-accessible location where your offline site is visible, and is included in the notification email Publish Offline sends after your site has been published. By default, this is your Blog Site URL with `/puboffline/` appended. The URL you enter here will be saved for the next time you wish to publish offline. (Note that if you have entered an Output File Path to an area of your server that is _not_ web-accessible, you should leave this field blank so that an invalid URL is not emailed.)
* Zip Offline Version - Check this checkbox to zip the offline contents for you. This is merely a convenience for users. Note that the `Archive::Zip` Perl module must be installed for this option to appear.
* Email Address - Enter an email address to be notified when the offline publishing process is complete. By default, the current user's email address is entered here. Leave this field blank if you don't want to receive an email when the process is complete.

After clicking the "Continue" button, the current blog will be sent to the Publish Queue to publish your site. Once the process is complete, the notification email is sent!

# Template Tags

The plugin also defines the following template tag: 

    <mt:IsOfflineMode><mt:Else></mt:IsOfflineMode>

This template tag can be used to output templates differently when publishing for offline distribution.

# Release Notes

* The copying of static files cannot follow symlinks. If your mt-static directory utilizes symlinks, please switch to hard links or physically copy the files to the mt-static directory.


# About Endevver

We design and develop web sites, products and services with a focus on 
simplicity, sound design, ease of use and community. We specialize in 
Movable Type and offer numerous services and packages to help customers 
make the most of this powerful publishing platform.

http://www.endevver.com/

# Support

For help with this plugin please visit http://help.endevver.com

# Copyright

Copyright 2010, Endevver, LLC. All rights reserved.

# License

This plugin is licensed under the same terms as Perl itself.
