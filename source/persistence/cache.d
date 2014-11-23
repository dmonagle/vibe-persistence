module persistence.cache;

import std.datetime;

struct CachedData(T) {
	SysTime timestamp;
	T data;
}

struct CacheContainer(T) {
	int maxAge = 4;
	int maxSize = 100;

	CachedData!T[string] _cacheMap;

	void addToCache(string id, T data) {
		_cacheMap[id] = CachedData!T(Clock.currTime(), data);
	}

	T retrieveFromCache(string id) {
		if (id in _cacheMap) {
			auto cachedModel = _cacheMap[id];
			auto age = Clock.currTime() - cachedModel.timestamp;
			if (age > dur!"seconds"(maxAge)) {
				_cacheMap.remove(id);
				return T(null);
			}

			return cachedModel.data;
		}
		return T(null);
	}

	@property size_t length() {
		return _cacheMap.length;
	}
}

unittest {
	import core.thread;
	import vibe.data.bson;
	
	auto testData1 = serializeToBson(["name": "Bruce"]);
	
	
	CacheContainer!Bson ca;
	ca.maxAge = 1;
	ca.maxSize = 100;
	
	assert(ca.length == 0);
	ca.addToCache("123", testData1);
	assert(ca.length == 1);
	
	auto result = ca.retrieveFromCache("123");
	assert(result.name.get!string == "Bruce");
	
	auto noResult = ca.retrieveFromCache("1234");
	assert(noResult.isNull);
	
	Thread.sleep( dur!("seconds")(1) );
	auto result2 = ca.retrieveFromCache("123");
	assert(result2.isNull);
	assert(ca.length == 0);
}

unittest {
	import core.thread;
	import vibe.data.json;
	
	auto testData1 = serializeToJson(["name": "Bruce"]);
		
	CacheContainer!Json ca;
	ca.maxAge = 1;
	ca.maxSize = 100;
	
	assert(ca.length == 0);
	ca.addToCache("123", testData1);
	assert(ca.length == 1);
	
	auto result = ca.retrieveFromCache("123");
	assert(result.name.get!string == "Bruce");

	auto noResult = ca.retrieveFromCache("1234");
	assert(noResult.type == Json.Type.null_);

	Thread.sleep( dur!("seconds")(1) );
	auto result2 = ca.retrieveFromCache("123");
	assert(noResult.type == Json.Type.null_);
	assert(ca.length == 0);
}

