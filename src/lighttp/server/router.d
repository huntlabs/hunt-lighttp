﻿module lighttp.server.router;

import std.algorithm : max;
import std.base64 : Base64;
import std.conv : to, ConvException;
import std.digest.sha : sha1Of;
import std.regex : Regex, isRegexFor, regex, matchAll;
import std.socket : Address;
import std.string : startsWith, join;
import std.traits : Parameters, hasUDA;

import hunt.io.TcpStream;

import lighttp.server.resource;
import lighttp.server.server : ServerOptions, Connection, MultipartConnection, WebSocketConnection;
import lighttp.util;

struct HandleResult {

	bool success;
	Connection connection = null;

}

/**
 * Router for handling requests.
 */
class Router {

	private static Resource indexPage;
	private static TemplatedResource errorPage;

	static this() {
		indexPage = new Resource("text/html", import("index.html"));
		errorPage = new TemplatedResource("text/html", import("error.html"));
	}

	private Route[][string] routes;

	private void delegate(ServerRequest, ServerResponse) _errorHandler;

	this() {
		this.add(Get(), indexPage);
		_errorHandler = &this.defaultErrorHandler;
	}

	/*
	 * Handles a connection.
	 */
	void handle(ServerOptions options, ref HandleResult result, TcpStream client, ServerRequest req, ServerResponse res) {
		if(!req.url.path.startsWith("/")) {
			res.status = StatusCodes.badRequest;
		} else {
			auto routes = req.method in this.routes;
			if(routes) {
				foreach_reverse(route ; *routes) {
					route.handle(options, result, client, req, res);
					if(result.success) return;
				}
			}
			res.status = StatusCodes.notFound;
		}
	}

	/*
	 * Handles a client or server error and displays an error
	 * page to the client.
	 */
	void handleError(ServerRequest req, ServerResponse res) {
		_errorHandler(req, res);
	}

	private void defaultErrorHandler(ServerRequest req, ServerResponse res) {
		errorPage.apply(["message": res.status.message, "error": res.status.toString(), "server": res.headers["Server"]]).apply(req, res);
	}

	/**
	 * Registers routes from a class's methods marked with the
	 * @Get, @Post and @CustomMethod attributes.
	 */
	void add(T)(T routes) {
		foreach(member ; __traits(allMembers, T)) {
			static if(__traits(getProtection, __traits(getMember, T, member)) == "public") {
				foreach(uda ; __traits(getAttributes, __traits(getMember, T, member))) {
					static if(is(typeof(uda)) && isRouteInfo!(typeof(uda))) {
						mixin("alias M = routes." ~ member ~ ";");
						static if(is(typeof(__traits(getMember, T, member)) == function)) {
							// function
							this.add(uda, mixin("&routes." ~ member));
						} else static if(is(M == class)) {
							// websocket
							static if(__traits(isNested, M)) this.addWebSocket!M(uda, { return routes.new M(); });
							else this.addWebSocket!M(uda);
						} else {
							// member
							this.add(uda, mixin("routes." ~ member));
						}
					}
				}
			}
		}
	}

	/**
	 * Adds a route.
	 */
	void add(T, E...)(RouteInfo!T info, void delegate(E) del) {
		if(info.hasBody) this.routes[info.method] ~= new MultipartRouteOf!(T, E)(info.path, del);
		else this.routes[info.method] ~= new RouteOf!(T, E)(info.path, del);
	}

	void add(T)(RouteInfo!T info, Resource resource) {
		this.add(info, (ServerRequest req, ServerResponse res){ resource.apply(req, res); });
	}

	void addWebSocket(W:WebSocketConnection, T)(RouteInfo!T info, W delegate() del) {
		static if(__traits(hasMember, W, "onConnect")) this.routes[info.method] ~= new WebSocketRouteOf!(W, T, Parameters!(W.onConnect))(info.path, del);
		else this.routes[info.method] ~= new WebSocketRouteOf!(W, T)(info.path, del);
	}

	void addWebSocket(W:WebSocketConnection, T)(RouteInfo!T info) if(!__traits(isNested, W)) {
		this.addWebSocket!(W, T)(info, { return new W(); });
	}

	void remove(T, E...)(RouteInfo!T info, void delegate(E) del) {
		//TODO
	}
	
}

class Route {

	abstract void handle(ServerOptions options, ref HandleResult result, TcpStream client, ServerRequest req, ServerResponse res);

}

class RouteImpl(T, E...) if(is(T == string) || isRegexFor!(T, string)) : Route {

	private T path;
	
	static if(E.length) {
		static if(is(E[0] == ServerRequest)) {
			enum __request = 0;
			static if(E.length > 1 && is(E[1] == ServerResponse)) enum __response = 1;
		} else static if(is(E[0] == ServerResponse)) {
			enum __response = 0;
			static if(E.length > 1 && is(E[1] == ServerRequest)) enum __request = 1;
		}
	}

	static if(!is(typeof(__request))) enum __request = -1;
	static if(!is(typeof(__response))) enum __response = -1;
	
	static if(__request == -1 && __response == -1) {
		alias Args = E[0..0];
		alias Match = E[0..$];
	} else {
		enum _ = max(__request, __response) + 1;
		alias Args = E[0.._];
		alias Match = E[_..$];
	}

	static assert(Match.length == 0 || !is(T : string));
	
	this(T path) {
		this.path = path;
	}
	
	void callImpl(void delegate(E) del, ServerOptions options, TcpStream client, ServerRequest req, ServerResponse res, Match match) {
		Args args;
		static if(__request != -1) args[__request] = req;
		static if(__response != -1) args[__response] = res;
		del(args, match);
	}
	
	abstract void call(ServerOptions options, ref HandleResult result, TcpStream client, ServerRequest req, ServerResponse res, Match match);
	
	override void handle(ServerOptions options, ref HandleResult result, TcpStream client, ServerRequest req, ServerResponse res) {
		static if(is(T == string)) {
			if(req.url.path[1..$] == this.path) {
				this.call(options, result, client, req, res);
				result.success = true;
			}
		} else {
			auto match = req.url.path[1..$].matchAll(this.path);
			if(match && match.post.length == 0) {
				string[] matches;
				foreach(m ; match.front) matches ~= m;
				Match args;
				static if(E.length == 1 && is(E[0] == string[])) {
					args[0] = matches[1..$];
				} else {
					if(matches.length != args.length + 1) throw new Exception("Arguments count mismatch");
					static foreach(i ; 0..Match.length) {
						args[i] = to!(Match[i])(matches[i+1]);
					}
				}
				this.call(options, result, client, req, res, args);
				result.success = true;
			}
		}
	}
	
}

class RouteOf(T, E...) : RouteImpl!(T, E) {

	private void delegate(E) del;
	
	this(T path, void delegate(E) del) {
		super(path);
		this.del = del;
	}
	
	override void call(ServerOptions options, ref HandleResult result, TcpStream client, ServerRequest req, ServerResponse res, Match match) {
		this.callImpl(this.del, options, client, req, res, match);
	}
	
}

class MultipartRouteOf(T, E...) : RouteOf!(T, E) {

	this(T path, void delegate(E) del) {
		super(path, del);
	}

	override void call(ServerOptions options, ref HandleResult result, TcpStream client, ServerRequest req, ServerResponse res, Match match) {
		if(auto lstr = "content-length" in req.headers) {
			try {
				size_t length = to!size_t(*lstr);
				if(length > options.max) {
					result.success = false;
					res.status = StatusCodes.payloadTooLarge;
				} else if(req.body_.length >= length) {
					return super.call(options, result, client, req, res, match);
				} else {
					// wait for full data
					result.connection = new MultipartConnection(client, length, req, res, { super.call(options, result, client, req, res, match); });
					res.ready = false;
					return;
				}
			} catch(ConvException) {
				result.success = false;
				res.status = StatusCodes.badRequest;
			}
		} else {
			// assuming body has no content
			super.call(options, result, client, req, res, match);
		}
	}

}

class WebSocketRouteOf(WebSocket, T, E...) : RouteImpl!(T, E) {

	private WebSocket delegate() createWebSocket;

	this(T path, WebSocket delegate() createWebSocket) {
		super(path);
		this.createWebSocket = createWebSocket;
	}

	override void call(ServerOptions options, ref HandleResult result, TcpStream client, ServerRequest req, ServerResponse res, Match match) {
		auto key = "sec-websocket-key" in req.headers;
		if(key) {
			res.status = StatusCodes.switchingProtocols;
			res.headers["Sec-WebSocket-Accept"] = Base64.encode(sha1Of(*key ~ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")).idup;
			res.headers["Connection"] = "upgrade";
			res.headers["Upgrade"] = "websocket";
			// create web socket and set callback for onConnect
			WebSocket webSocket = this.createWebSocket();
			webSocket.conn = client;
			result.connection = webSocket;
			static if(__traits(hasMember, WebSocket, "onConnect")) webSocket.onStartImpl = { this.callImpl(&webSocket.onConnect, options, client, req, res, match); };
		} else {
			res.status = StatusCodes.notFound;
		}
	}

}

struct RouteInfo(T) if(is(T : string) || is(T == Regex!char) || isRegexFor!(T, string)) {
	
	string method;
	bool hasBody;
	T path;

}

auto routeInfo(E...)(string method, bool hasBody, E path) {
	static if(E.length == 0) {
		return routeInfo(method, hasBody, "");
	} else static if(E.length == 1) {
		static if(isRegexFor!(E[0], string)) return RouteInfo!E(method, hasBody, path);
		else return RouteInfo!(Regex!char)(method, hasBody, regex(path));
	} else {
		string[] p;
		foreach(pp ; path) p ~= pp;
		return RouteInfo!(Regex!char)(method, hasBody, regex(p.join(`\/`)));
	}
}

private enum isRouteInfo(T) = is(T : RouteInfo!R, R);

auto CustomMethod(R)(string method, bool hasBody, R path){ return routeInfo!R(method, hasBody, path); }

auto Get(R...)(R path){ return routeInfo!R("GET", false, path); }

auto Post(R...)(R path){ return routeInfo!R("POST", true, path); }

auto Put(R...)(R path){ return routeInfo!R("PUT", true, path); }

auto Delete(R...)(R path){ return routeInfo!R("DELETE", false, path); }

void registerRoutes(R)(Router register, R router) {

	foreach(member ; __traits(allMembers, R)) {
		static if(__traits(getProtection, __traits(getMember, R, member)) == "public") {
			foreach(uda ; __traits(getAttributes, __traits(getMember, R, member))) {
				static if(is(typeof(uda)) && isRouteInfo!(typeof(uda))) {
					mixin("alias M = router." ~ member ~ ";");
					static if(is(typeof(__traits(getMember, R, member)) == function)) {
						// function
						static if(hasUDA!(__traits(getMember, R, member), Multipart)) register.addMultipart(uda, mixin("&router." ~ member));
						else register.add(uda, mixin("&router." ~ member));
					} else static if(is(M == class)) {
						// websocket
						static if(__traits(isNested, M)) register.addWebSocket!M(uda, { return router.new M(); });
						else register.addWebSocket!M(uda);
					} else {
						// member
						register.add(uda, mixin("router." ~ member));
					}
				}
			}
		}
	}
	
}
