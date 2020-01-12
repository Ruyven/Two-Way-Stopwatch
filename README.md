Two Way Stopwatch
=================

A stopwatch that can run forwards or backwards, supporting macOS and iOS.

It includes sync over Dropbox, so you can start the stopwatch on your Mac, launch the app on your iPhone and it will sync the current time and detect that it's running, and in which direction.

How to set up Dropbox sync
--------------------------

I have yet to set up oauth, because I've only been using it by myself.

Here's the current way to set up Dropbox sync:

- Log into [Dropbox Developers](https://www.dropbox.com/developers/apps)
- Create a new app
- Choose "Dropbox API"
- Choose "App folder"
- Name your app, e.g. TwoWayStopwatch
- [Generate an access token](https://blogs.dropbox.com/developers/2014/05/generate-an-access-token-for-your-own-account/) to work with your own account
- Add the token as DROPBOX_ACCESS_TOKEN in DataManager.swift.

To do:
------
- Add oauth process for users to authenticate themselves with Dropbox
- Add proper error handling if Dropbox is not authenticated
- Create app icons
- Bug: Dock icon can show -0:00
- Mac version: Add option to cancel the current session if it's been running for a long time, in case it's still running only by accident. (The iOS version already has that feature, if the session has been running for over 30 minutes.)
