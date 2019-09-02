module lighttp.client.client;

import std.conv : to, ConvException;

import hunt.io;
import hunt.event;
import hunt.collection.ByteBuffer;

import lighttp.util;

struct ClientOptions {

	bool closeOnSuccess = false;

	bool closeOnFailure = false;

	//bool followRedirect = false;

}

class Client {

	private EventLoop _eventLoop;
	private ClientOptions _options;

	this(EventLoop eventLoop, ClientOptions options=ClientOptions.init) {
		_eventLoop = eventLoop;
		_options = options;
	}

	//this(ClientOptions options=ClientOptions.init) {
	//	this(getThreadEventLoop(), options);
	//}

	@property ClientOptions options() pure nothrow @safe @nogc {
		return _options;
	}

	@property EventLoop eventLoop() pure nothrow @safe @nogc {
		return _eventLoop;
	}

	ClientConnection connect(string ip, ushort port=80) {
		return new ClientConnection(new TcpStream(_eventLoop), ip, port);
	}

	class ClientConnection {

		private TcpStream _connection;

		private bool _connected = false;
		private bool _performing = false;
		private bool _successful;

		private immutable string host;

		private size_t _contentLength;
		private void delegate() _handler;

		private ClientResponse _response;

		private void delegate(ClientResponse) _success;
		private void delegate() _failure;

		this(TcpStream connection, string ip, ushort port) {
			_connection = connection;
			_connection.onReceived(&this.onRead);
			_connection.onConnected((bool isSucceeded) {
				if (isSucceeded) {
					_connected = true;
				}
			});
			_connection.connect(ip, port);

			this.host = ip ~ (port != 80 ? ":" ~ to!string(port) : "");
		}

		auto perform(ClientRequest request) {
			assert(!_performing);
			_performing = true;
			_successful = false;
			request.headers["Host"] = this.host;
			if(_connected) {
				_connection.write(cast(ubyte[])request.toString());
			} else {
				//_buffer.reset();
				//_buffer.write(request.toString());
			}
			return this;
		}
		
		auto get(string path) {
			return this.perform(new ClientRequest("GET", path));
		}
		
		auto post(string path, string body_) {
			return this.perform(new ClientRequest("POST", path, body_));
		}

		auto success(void delegate(ClientResponse) callback) {
			_success = callback;
			return this;
		}

		auto failure(void delegate() callback) {
			_failure = callback;
			return this;
		}

		bool close() {
			_connection.close();
			return true;
		}
		
		private void onRead(ByteBuffer buffer) {
			ClientResponse response = new ClientResponse();
			if(response.parse(cast(string)buffer.getRemaining())) {
				if(auto contentLength = "content-length" in response.headers) {
					try {
						_contentLength = to!size_t(*contentLength);
						if(_contentLength > response.body_.length) {
							_response = response;
							this.handleLong(buffer);
							return;
						}
					} catch(ConvException) {
						_performing = false;
						_successful = false;
						_failure();
						if(_options.closeOnFailure) this.close();
						return;
					}
				}
				_performing = false;
				_successful = true;
				_success(response);
				if(_options.closeOnSuccess) this.close();
			} else {
				_performing = false;
				_successful = false;
				_failure();
				if(_options.closeOnFailure) this.close();
			}
		}

		private void handleLong(ByteBuffer buffer) {
			_response.body_ = _response.body_ ~ cast(char[])buffer.getRemaining();
			if(_response.body_.length >= _contentLength) {
				_performing = false;
				_successful = true;
				_success(_response);
				if(_options.closeOnSuccess) this.close();
			}
		}
	}
}
