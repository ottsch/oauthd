# OAuth daemon
# Copyright (C) 2013 Webshell SAS
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

async = require 'async'
qs = require 'querystring'
Url = require 'url'
restify = require 'restify'
request = require 'request'

module.exports = (env) ->


	oauth = env.utilities.oauth

	exp = {}
	exp.raw = ->

		fixUrl = (ref) -> ref.replace /^([a-zA-Z\-_]+:\/)([^\/])/, '$1/$2'

		@apiRequest = (req, provider_name, oauthio, callback) =>
			req.headers ?= {}
			async.parallel [
				(callback) => @db.providers.getExtended provider_name, callback
				(callback) => @db.apps.getKeyset oauthio.k, provider_name, callback
			], (err, results) =>
				return callback err if err
				[provider, {parameters}] = results

				# select oauth version
				oauthv = oauthio.oauthv && {
					"2":"oauth2"
					"1":"oauth1"
				}[oauthio.oauthv]
				if oauthv and not provider[oauthv]
					return callback new @check.Error "oauthio_oauthv", "Unsupported oauth version: " + oauthv

				oauthv ?= 'oauth2' if provider.oauth2
				oauthv ?= 'oauth1' if provider.oauth1

				parameters.oauthio = oauthio

				# let oauth modules do the request
				oa = new oauth[oauthv](provider, parameters)
				oa.request req, callback

		doRequest = (req, res, next) =>
			cb = @server.send(res, next)
			oauthio = req.headers.oauthio
			if ! oauthio
				return cb new @check.Error "You must provide a valid 'oauthio' http header"
			oauthio = qs.parse(oauthio)
			if ! oauthio.k
				return cb new @check.Error "oauthio_key", "You must provide a 'k' (key) in 'oauthio' header"

			origin = null
			ref = fixUrl(req.headers['referer'] || req.headers['origin'] || "http://localhost");
			urlinfos = Url.parse(ref)
			if not urlinfos.hostname
				ref = origin = "http://localhost"
			else
				origin = urlinfos.protocol + '//' + urlinfos.host

			req.apiUrl = decodeURIComponent(req.params[1])

			@db.apps.checkDomain oauthio.k, ref, (err, domaincheck) =>
				return cb err if err
				if ! domaincheck
					return cb new @check.Error 'Origin "' + ref + '" does not match any registered domain/url on ' + @config.url.host

			@apiRequest req, req.params[0], oauthio, (err, options) =>
				return cb err if err

				@events.emit 'request', provider:req.params[0], key:oauthio.k

				api_request = null

				sendres = ->
					api_request.pipefilter = (response, dest) ->
						dest.setHeader 'Access-Control-Allow-Origin', origin
						dest.setHeader 'Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE'
					api_request.pipe(res)
					api_request.once 'end', -> next false

				if req.headers['content-type'] and req.headers['content-type'].indexOf('application/x-www-form-urlencoded') != -1
					bodyParser = restify.bodyParser mapParams:false
					bodyParser[0] req, res, -> bodyParser[1] req, res, ->
						options.form = req.body
						delete options.headers['Content-Length']
						api_request = request options
						sendres()
				else
					api_request = request options
					delete req.headers
					api_request = req.pipe(api_request)
					sendres()


		# request's endpoints
		@server.opts new RegExp('^/request/([a-zA-Z0-9_\\.~-]+)/(.*)$'), (req, res, next) ->
			origin = null
			ref = fixUrl(req.headers['referer'] || req.headers['origin'] || "http://localhost");
			urlinfos = Url.parse(ref)
			if not urlinfos.hostname
				return next new restify.InvalidHeaderError 'Missing origin or referer.'
			origin = urlinfos.protocol + '//' + urlinfos.host

			res.setHeader 'Access-Control-Allow-Origin', origin
			res.setHeader 'Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE'
			if req.headers['access-control-request-headers']
				res.setHeader 'Access-Control-Allow-Headers', req.headers['access-control-request-headers']
			res.cache maxAge: 120

			res.send 200
			next false

		@server.get new RegExp('^/request/([a-zA-Z0-9_\\.~-]+)/(.*)$'), doRequest
		@server.post new RegExp('^/request/([a-zA-Z0-9_\\.~-]+)/(.*)$'), doRequest
		@server.put new RegExp('^/request/([a-zA-Z0-9_\\.~-]+)/(.*)$'), doRequest
		@server.patch new RegExp('^/request/([a-zA-Z0-9_\\.~-]+)/(.*)$'), doRequest
		@server.del new RegExp('^/request/([a-zA-Z0-9_\\.~-]+)/(.*)$'), doRequest
	exp
