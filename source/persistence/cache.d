module persistence.cache;

import vibe.data.bson;
import std.datetime;

struct CachedModel {
	SysTime timestamp;
	Bson data;
}

struct ModelCache {
	int maxAge = 4;
	int maxSize = 100;

	CachedModel[string] _cacheMap;

	void addToCache(string id, const ref Bson data) {
		_cacheMap[id] = CachedModel(Clock.currTime(), data);
	}

	Bson retrieveFromCache(string id) {
		if (id in _cacheMap) {
			auto cachedModel = _cacheMap[id];
			auto age = Clock.currTime() - cachedModel.timestamp;
			if (age > dur!"seconds"(maxAge)) {
				_cacheMap.remove(id);
				return Bson(null);
			}

			return cachedModel.data;
		}
		return Bson(null);
	}

	@property size_t length() {
		return _cacheMap.length;
	}
}

unittest {
	import core.thread;

	auto testData1 = serializeToBson(["name": "Bruce"]);

	
	ModelCache ca;
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

