A Ruby SDK for accessing your Trackvia application data.

## Features

1. Simple client to access the Trackvia API

## Installation

Add to your application's Gemfile:

  gem 'trackvia-api-sdk'

Then execute:

  bundle install

## Usage

Start by trying to authenticate your user and make a simple request:

```
  @client = Trackvia::Client.new(user_key: "abcd1234")
  @client.authorize('username', 'password')
  apps = @client.get_apps()
```

Obtain a user key by enabling the API at:

  https://go.trackvia.com/#/my-info

Note, the API is only available for Enterprise level accounts

Source code:

  https://github.com/Trackvia/API-Ruby-SDK


### Logging

Client logs are stored in:

  trackvia-client.log

Automatic log-file rotation occurs every 7 days.

HTTP logging is managed by rest-client, saved to a file specified by whatever file
name is assigned to the environment variable, RESTCLIENT_LOG.

  export RESTCLIENT_LOG=/path/to/your/logfile

