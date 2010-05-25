This plugin allows for users to publish a site to alternate directory. It will automatically publish the entire site to that directory, as well as all static files, and before writing files to the target directory rewrite all URLs accordingly so that they use the `file://` syntax as opposed to `http://`.

# Usage

To publish a site for offline use, navigate to the List Templates screen. Then click "Publish Offline Version" in the page actions widget on the right hand side.

# Template Tags

The plugin also defines the following template tag: 

    <mt:IfOfflineMode><mt:Else></mt:IfOfflineMode>

This template tag can be used to output templates differently when publishing for offline distribution. 

# Release Notes

* The copying of static files cannot follow symlinks. If your mt-static directory utilizes symlinks, please switch to hard links or physically copy the files to the mt-static directory.

# Installation

To install this plugin follow the instructions found here:

http://tinyurl.com/easy-plugin-install

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