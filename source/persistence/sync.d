module persistence.sync;

import persistence.mongodb;
import std.typecons;
public import std.digest.sha;

/* This set of structs could certainly use some better methods of updating other than calling save
 * It could probably get to the point of not requiring an explicit save but to use updates 
 * in order to mark changes
*/

alias SyncHash = ubyte[];

struct SyncServiceMeta {
	SyncHash syncHash = []; 
	Nullable!SysTime syncedAt;
	
	bool needsSync(SyncHash modelHash) {
		return (modelHash != syncHash);
	}
}

/// Most of this struct is not meant to be used directly. Instead use ModelSyncMeta
struct SyncMeta {
	mixin MongoModel!SyncMeta;
	
	string modelType;
	BsonObjectID modelId;
	SyncServiceMeta[string] services;
	@ignore SyncHash _syncHash;
	
	// This should only be called directly if the _syncHash has been updated from the model.
	// Likely you will want to use the synced property of ModelSyncMeta instead.
	@property bool synced() {
		foreach(serviceName, serviceMeta; services) {
			if (serviceMeta.needsSync(_syncHash)) return false;
			return true;
		}
		return false;
	}
	
	/// This only exists so the serializer deals with the synced property
	@property void synced(bool value) { }
	
	/// Returns the service specified by serviceName
	ref SyncServiceMeta opIndex(string serviceName) {
		return services[serviceName];
	}

	bool serviceExists(string serviceName) const {
		return cast(bool)(serviceName in services);
	}
	
	/// Returns the specified serviceName, creating it if necessary
	ref SyncServiceMeta ensureService(string serviceName) {
		if (!serviceExists(serviceName)) {
			auto serviceMeta = SyncServiceMeta();
			services[serviceName] = serviceMeta;
		}
		return services[serviceName];
	}
	
	/// Takes a list of serviceNames and ensures all of them exist
	void ensureServices(const string[] requiredServices ...) {
		foreach(serviceName; requiredServices) {
			ensureService(serviceName);
		}
	}
	
	/// Returns true if the specified service does not match the given syncHash
	/// Returns false if the service doesn't exist or is up to date
	bool serviceNeedsSync(string serviceName, SyncHash syncHash) {
		if (!serviceExists(serviceName)) return false;
		auto service = this[serviceName];
		return service.needsSync(syncHash);
	}
}

struct ModelSyncMeta(M) {
	private {
		@ignore const M _model;
	}
	
	SyncMeta _syncMeta;
	
	this(const M model, const string[] requiredServices ...) {
		_model = model;
		
		assert(model._id.valid, "You can only use SyncMeta on a model with an Id");
		
		auto query = ["modelType": Bson(M.stringof), "modelId": Bson(model._id)].serializeToBson;
		_syncMeta.mongoAdapter.find!SyncMeta(query, (result) {
			_syncMeta.deserializeBson(result);
		}, 1);
		
		if (!_syncMeta._id.valid) {
			_syncMeta.modelId = model._id;
			_syncMeta.modelType = M.stringof;
		}
		
		_syncMeta.ensureServices(requiredServices);
	}
	
	ref SyncServiceMeta opIndex(string serviceName) {
		return _syncMeta[serviceName];
	}
	
	bool save() {
		_syncMeta._syncHash = _model.syncHash;
		return _syncMeta.save();
	}

	@property bool changed() const {
		return cast(bool)(_syncMeta._syncHash != _model.syncHash);
	}

	@property bool synced() {
		_syncMeta._syncHash = _model.syncHash;
		return _syncMeta.synced;
	}
	
	bool updateSync(string serviceName) {
		auto primaryHash = _model.syncHash;
		auto serviceMeta = this[serviceName];
		if (serviceMeta.syncHash != primaryHash) {
			serviceMeta.syncHash = primaryHash;
			serviceMeta.syncedAt = Clock.currTime;
			this[serviceName] = serviceMeta;
			return true;
		}
		return false;
	}
	
	void ensureServices(const string[] requiredServices ...) {
		_syncMeta.ensureServices(requiredServices);
	}
	
	void ensureService(string serviceName) {
		_syncMeta.ensureService(serviceName);
	}
	
	bool serviceNeedsSync(string serviceName) {
		if (!_syncMeta.serviceExists(serviceName)) return false;
		auto service = this[serviceName];
		return service.needsSync(_model.syncHash);
	}
	
}

/// Helper function to initialize a ModelSyncMeta!M struct
ModelSyncMeta!M modelSync(M)(const M model, const string[] requiredServices ...) {
	return ModelSyncMeta!M(model, requiredServices);
}

version (unittest) {
	import std.datetime;
	
	import vibe.d;
	import std.digest.sha;
	import std.datetime;
	import std.stdio;
	
	class UserModel {
		string name;
		int age;
		
		mixin MongoModel!UserModel;
	}
	
	class UserWithDate {
		string name;
		int age;
		SysTime dateTime;
		
		const Json jsonForSync() {
			Json json = this.serializeToJson;
			
			json.remove("dateTime");
			
			return json;
		}
		
	}
	
}

unittest {
	import std.exception;
	
	auto mongoAdapter = new MongoAdapter("mongodb://localhost/", "geo_server", "unittest");
	
	mongoAdapter.dropCollection("sync_meta");
	mongoAdapter.registerModel!SyncMeta(ModelMeta("sync_meta"));
	mongoAdapter.ensureIndex!SyncMeta(["modelType": 1, "modelId": 1], IndexFlags.Unique);
	mongoAdapter.dropCollection("user_models");
	mongoAdapter.registerModel!UserModel(ModelMeta("user_models"));
	
	auto u = new UserModel;
	u.name = "David";
	u.age = 35;
	
	// We cannot retrieve a ModelSyncMeta struct for a model that has no Id
	assertThrown!AssertError(modelSync(u));
	
	// Saving the user creates the Id
	u.save;
	
	// We should now be able to get the ModelSyncMeta with a call to modelSync with the model
	// also we make sure the services we require exist
	auto sync = modelSync(u, "webService1", "webService2");

	assert(!sync.serviceNeedsSync("undefinedService"));

	// Both of the new services need syncing
	assert(sync.serviceNeedsSync("webService1"));
	assert(sync.serviceNeedsSync("webService2"));
	
	// As the ModelSyncMeta is bound to the original object. We can mark as service as synced like this
	sync.updateSync("webService1");
	assert(!sync.serviceNeedsSync("webService1"));
	assert(sync.serviceNeedsSync("webService2"));
	
	sync.updateSync("webService2");
	assert(sync.synced); // Should return true as both services are synced
	
	// Now if we change the model and update webService2, webService1 should need syncing
	u.age = 36;
	sync.updateSync("webService2");
	assert(!sync.synced); // We are not synced as webService1 still needs to be updated
	assert(sync.serviceNeedsSync("webService1"));
	assert(!sync.serviceNeedsSync("webService2"));
	
	sync.save;
	
	// If we retrieve this from the database, assert that it's getting the saved syncHash values
	auto retrievedSync = modelSync(u);
	u.age = 37;
	assert(sync["webService1"].syncHash.length);
	
}

SyncHash syncHash(M, string hashFunction = "sha1Of")(const M model) {
	static if (__traits(compiles, model.stringForSyncHash)) {
		string stringForHash = model.stringForSyncHash;
	}
	else {
		static if (__traits(compiles, model.jsonForSync)) {
			Json jsonForHash = model.jsonForSync;
		}
		else {
			Json jsonForHash = model.serializeToJson;
		}
		string stringForHash = jsonForHash.toString;
	}
	
	return mixin(hashFunction ~ "(stringForHash)").dup;
}

unittest {
	auto u = new UserModel;
	u.name = "David";
	u.age = 35;
	
	auto savedHash = u.syncHash;
	u.age = 36;
	assert(savedHash != u.syncHash);
}

unittest {
	import core.time;
	
	auto u = new UserWithDate;
	u.name = "David";
	u.age = 35;
	
	u.dateTime = Clock.currTime;
	auto savedHash = u.syncHash;
	u.dateTime = Clock.currTime + 1.minutes;
	assert(savedHash == u.syncHash);
}

