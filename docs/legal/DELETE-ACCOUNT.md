# Delete your PocketDJ account and data

**Effective date: October 29, 2026**

<!-- Source of https://legal.pocket-dj.com/delete-account/ — the web account-deletion URL that
Google Play's Data safety form requires (also linked from PRIVACY.md §13 and www/support.html).
Build: node scripts/legal-site-build.mjs. Keep in step with AccountDeletionService on both
platforms (apple/PocketDJ/…/AccountDeletionService.swift, android/…/data/reset/AccountDeletionService.kt). -->

This page explains how to delete your account and data for **PocketDJ**, the music library and DJ app published by African Intellect Enterprises LLC (PocketDJ), on iPhone, iPad, Mac, Apple TV, Apple Vision Pro, and Android (Google Play and the direct download from pocket-dj.com).

PocketDJ has no username or password. Your account is the **profile** the app creates on first run: a random identifier and the display name you choose.

## Option 1: delete in the app (immediate)

- **Android:** open PocketDJ ▸ **Settings** ▸ **Reset** ▸ **Delete account**, then confirm.
- **iPhone, iPad, Mac, Apple TV, Apple Vision Pro:** open PocketDJ ▸ **Settings** ▸ **Profile** ▸ **Delete Account**, then confirm.

If you only want to remove what the cloud features uploaded and keep using the app as it is, use **Settings ▸ Recommendations ▸ Delete cloud data** instead.

## Option 2: ask us by email (no app needed)

If you no longer have the app or can't open it, email **[support@pocket-dj.com](mailto:support@pocket-dj.com?subject=Delete%20my%20PocketDJ%20data)** with the subject "Delete my PocketDJ data". Tell us which devices you used and, if you can, your PocketDJ display name, so we can find your data. We will delete it and confirm by reply within one month. We may ask a follow-up question to make sure the request comes from you.

## What gets deleted

| Data | What happens |
|---|---|
| Recommendation Engine data: listening history, favorites, feedback, collections and their names, play counts | Deleted from our servers |
| Listening-pocket data: play events, place and trip labels, walking/running labels, computed pockets, "In the Pocket" rounds and feedback | Deleted from our servers |
| Android profile-sync data (if you turned sync on) | Deleted from our servers |
| Jukebox sessions you are hosting, and your Music with Friends registration | Ended and withdrawn |
| PocketDJ records in your private iCloud database (Apple devices, in-app deletion) | Deleted |
| Everything PocketDJ stores on the device: library, collections, history, downloads, recordings, places, credentials | Erased (in-app deletion) |
| Your profile identifier and installation identifier | Reset, so nothing new can be linked to the old ones |

## What is kept, and for how long

| Data | Kept for |
|---|---|
| Content delivery network request logs (IP address, time, address requested) | Up to 365 days, then deleted automatically |
| Diagnostic logs from TestFlight and development builds | Up to 14 days, then deleted automatically |
| Copies of jukebox sessions | Up to 7 days after the session was created |
| Operational logs of our cloud functions (request metadata, not your library) | Not yet on a fixed schedule |
| Data in your own iCloud or Google account (for example an Android backup), if you deleted the app without using in-app deletion | Until you remove it there: Apple Settings ▸ your name ▸ iCloud ▸ Manage Storage, or your Google account's backup settings |

The [Privacy Policy](https://legal.pocket-dj.com/privacy/) has the full details of what PocketDJ collects and why.
