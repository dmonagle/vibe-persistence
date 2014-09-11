module persistence.mongodb;

import persistence.cache;
public import persistence.exceptions;

public import vibe.db.mongo.mongo;
public import vibe.data.bson;
public import vibe.core.log;
public import std.datetime;
public import persistence.base;

class MongoAdapter : PersistenceAdapter {
	private {
		MongoClient _client;
		string _url;
		bool _connected;

		CacheContainer!Bson _cache;
	}
	@property bool connected() { return _connected; }
	
	@property MongoClient client() {
		if (!connected) {
			_client = connectMongoDB(_url);
			_connected = true;
		}
		return _client;
	}

	@property MongoDatabase database() {
		return client.getDatabase(fullName);
	}

	this(string url, string applicationName, string environment = "test") {
		super(applicationName, environment);
		_url = url;
	}

	Bson dropCollection(string collection) {
		auto command = Bson.emptyObject;
		command.drop = collection;
		return database.runCommand(command);
	}

	MongoCollection getCollection(string collection) {
		return client.getCollection(collectionPath(collection));
	}

	MongoCollection getCollection(ModelType)() {
		return getCollection(modelMeta!ModelType.containerName);
	}

	string collectionPath(string name) {
		return fullName ~ "." ~ name;
	}
	
	void ensureIndex(M)(int[string] fieldOrders, IndexFlags flags = cast(IndexFlags)0) {
		getCollection!M.ensureIndex(fieldOrders, flags);
	}

	ModelType findModel(ModelType, string key = "_id", IdType)(IdType id) {
		import std.conv;

		auto models = findModel!(ModelType, key, IdType)([id]);
		if (models.length) return models[0];
		static if(is(ModelType == class)) return null;
		else throw new NoModelForIdException("Could not find model with id " ~ to!string(id) ~ " in " ~ modelMeta!ModelType.containerName);
	}

	void findModel(ModelType)(Json options, scope void delegate(ModelType model) pred = null) {
		import std.array;
		import std.algorithm;

		auto collection = getCollection!ModelType;
		options._type = modelMeta!ModelType.type;
		
		auto result = collection.find(options);
		
		while (!result.empty) {
			ModelType model;
			auto bsonModel = result.front;
			deserializeBson(model, bsonModel);
			if (pred) pred(model);
			result.popFront;
		}
	}

	ModelType[] findModel(ModelType, string key = "_id", IdType)(IdType[] ids ...) {
		import std.array;
		import std.algorithm;
		
		ModelType[] models;

		auto collection = getCollection!ModelType;

		auto result = collection.find([key: ["$in": ids]]);
		
		while (!result.empty) {
			ModelType model;
			auto bsonModel = result.front;
			deserializeBson(model, bsonModel);
			models ~= model;
			result.popFront;
		}
		return models;
	}
	
	Bson find(ModelType, string key = "_id", IdType)(IdType id) {
		import std.conv;
		
		auto models = find!(ModelType, key, IdType)([id]);
		if (models.length) return models[0];
		return Bson(null);
	}
	
	Bson[] find(ModelType, string key = "_id", IdType)(IdType[] ids ...) {
		import std.array;
		import std.algorithm;
		
		Bson[] models;
		
		auto collection = getCollection(modelMeta!ModelType.containerName);
		auto result = collection.find([key: ["$in": ids]]);
		
		while (!result.empty) {
			models ~= result.front;
			result.popFront;
		}

		return models;
	}
	
	bool save(M)(ref M model) {
		auto collection = getCollection(modelMeta!M.containerName);

		Bson bsonModel;

		ensureEmbeddedIds(model);
		if(model.isNew) {
			model.ensureId();
			bsonModel = serializeToBson(model);
			collection.insert(model);
		} else {
			bsonModel = serializeToBson(model);
			collection.update(["_id": model.id], bsonModel, UpdateFlags.Upsert);
		}
		
		_cache.addToCache(bsonModel._id.toString(), bsonModel);
		
		return true;
	}

	void ensureEmbeddedIds(M)(ref M model) {
		import persistence.traits;

		foreach (memberName; __traits(allMembers, M)) {
			static if (isRWPlainField!(M, memberName) || isRWField!(M, memberName)) {
				alias member = Tuple!(__traits(getMember, M, memberName));
				alias embeddedUDA = findFirstUDA!(EmbeddedAttribute, member);
				static if (embeddedUDA.found) {
					auto embeddedModel = __traits(getMember, model, memberName);
					if (embeddedModel) embeddedModel.ensureId();
				}
			}
		}
	}
}

mixin template MongoModel(ModelType, string cName = "") {
	private {
		static PersistenceAdapter _persistenceAdapter;
	}

	@optional BsonObjectID _id;

	// Dummy setter so that _type will be serialized
	@optional @property void _type(string value) {}
	@property string _type() { return ModelType.stringof; }

	@ignore @property BsonObjectID id() { return _id; } 
	@optional @property void id(BsonObjectID id) { _id = id; } 
	@ignore @property bool isNew() { return !id.valid; }

	@ignore static @property ref PersistenceAdapter persistenceAdapter() { 
		return _persistenceAdapter; 
	}
	@ignore static @property MongoAdapter mongoAdapter() { 
		assert(_persistenceAdapter, "persistenceAdapter not set on " ~ ModelType.stringof);
		return cast(MongoAdapter)persistenceAdapter; 
	}

	@property SysTime createdAt() {
		return id.timeStamp;
	}

	void ensureId() {
		if (!id.valid) {
			id = BsonObjectID.generate();
		}
	}
}

version(unittest) {

	struct PersistenceTestUser {
		string firstName;
		string surname;
		
		mixin MongoModel!PersistenceTestUser;
	}
	
	class PersistenceTestPerson {
		string name;
		
		mixin MongoModel!PersistenceTestPerson;
	}
	
	unittest {
		auto mongodb = new MongoAdapter("mongodb://localhost", "testdb", "development");
		assert(mongodb.fullName == "testdb_development");
		assert(mongodb.collectionPath("test") == "testdb_development.test");
		mongodb.registerModel!PersistenceTestUser(ModelMeta("users"));
		
		PersistenceTestUser u;
		u.firstName = "David";
		
		assert(u.isNew);
		mongodb.save(u);
		assert(!u.isNew);
		
		auto loadedUser = mongodb.findModel!PersistenceTestUser(u.id);
		assert(loadedUser.firstName == "David");
	}
	
	unittest {
		import std.exception;
		
		auto mongodb = new MongoAdapter("mongodb://localhost", "testdb", "development");
		mongodb.registerModel!PersistenceTestPerson(ModelMeta("people"));
		
		assert(mongodb.fullName == "testdb_development");
		assert(mongodb.collectionPath("test") == "testdb_development.test");
		
		auto p = new PersistenceTestPerson;
		p.name = "David";
		
		assert(p.isNew);
		mongodb.save(p);
		assert(!p.isNew);
		
		auto loadedUser = mongodb.findModel!PersistenceTestPerson(p.id);
		assert(loadedUser.name == "David");
		
		assertThrown!NoModelForIdException(mongodb.find!PersistenceTestPerson("000000000000000000000000"));
	}
}

