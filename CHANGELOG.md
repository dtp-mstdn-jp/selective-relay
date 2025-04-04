# Changelog

## [0.2.3] - 2025-04-05

### Added

- Added a systemd unit file to start multiple server processes and multiple worker processes.

### Changed

- Changed to use up to three Redis servers (REDIS_URL, CACHE_REDIS_URL, SIDEKIQ_REDIS_URL)
- The subscription list, which was obtained by Redis key scanning, has been changed to be obtained from the cache Redis set type, improving performance.

### Fixed

- Updated shards

## [0.2.2] - 2024-12-23

### Changed

- When a user subscribes to a hashtag or account post, the subscription will not be sent if the server is the same as the poster's server

### Fixed

- Updated shards

## [0.2.1] - 2022-12-06

### Fixed

- Fixed to compile with Crystal 1.0.0 and later
- Updated shards

## [0.2.0] - 2020-03-07

From this version, noellabo forked it to 'selective-relay', which relays only activities that meet the conditions.

### Added

- Added an actor (relayctl) that mediates commands
- Added a function to read details from a configuration file about the actor (relay) that mediates transfers and the actor (relayctl) that mediates commands
- Added a function that allows users to register themselves as a relay and deliver their own posts, or receive posts with specified hashtags or posts from specified accounts

### Changed

- Changed to relay only activities that meet the conditions (default: limited to notes that include hashtags)

## [0.1.0] - 2018-09-03

- Original version of pub-relay by Chris Hobbs (RX14)
