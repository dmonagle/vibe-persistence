module persistence.mongodb;

import persistence.cache;
public import persistence.exceptions;

public import vibe.db.mongo.mongo;
public import vibe.data.bson;
public import vibe.core.log;
public import std.datetime;
import persistence.base;

class MongoAdapter {
	private {
		MongoClient _client;
		string _url;
		string _environment;
		string _database;
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
		return client.getDatabase(fullDatabaseName);
	}

	this(string url, string database, string environment = "test") {
		_url = url;
		_database = database;
		_environment = environment;
	}

	Bson dropCollection(string collection) {
		auto command = Bson.emptyObject;
		command.drop = collection;
		return database.runCommand(command);
	}

	MongoCollection getCollection(string collection) {
		return client.getCollection(collectionPath(collection));
	}
	string collectionPath(string name) {
		return fullDatabaseName ~ "." ~ name;
	}
	
	@property string fullDatabaseName() {
		return _database ~ "_" ~ _environment;
	}
	
	void ensureIndex(string collectionName, int[string] fieldOrders, IndexFlags flags = cast(IndexFlags)0) {
		auto collection = getCollection(collectionName);
		collection.ensureIndex(fieldOrders, flags);
	}

	ModelType findModel(ModelType, string key = "_id", IdType)(IdType id) {
		import std.conv;

		auto models = findModel!(ModelType, key, IdType)([id]);
		if (models.length) return models[0];
		static if(is(ModelType == class)) return null;
		else throw new NoModelForIdException("Could not find model with id " ~ to!string(id) ~ " in " ~ ModelType.containerName);
	}

	ModelType[] findModel(ModelType, string key = "_id", IdType)(IdType[] ids ...) {
		import std.array;
		import std.algorithm;
		
		ModelType[] models;
		
		auto collection = getCollection(ModelType.containerName);
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
		
		auto collection = getCollection(ModelType.containerName);
		auto result = collection.find([key: ["$in": ids]]);
		
		while (!result.empty) {
			models ~= result.front;
			result.popFront;
		}

		return models;
	}
	
	bool save(M)(ref M model) {
		auto collection = getCollection(M.containerName);

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
					__traits(getMember, model, memberName).ensureId();
				}
			}
		}
	}

	void registerModel(M, string containerName)(bool cached = true) {
		M.mongoAdapter = this;
		M.containerName = containerName;
	}
}

mixin template MongoModel(ModelType, string cName = "") {
	package {
		static string _containerName = cName;
		static MongoAdapter _mongoAdapter;
	}

	@ignore @property static MongoAdapter mongoAdapter() { return _mongoAdapter; }
	@ignore @property static void mongoAdapter(MongoAdapter a) { _mongoAdapter = a; }
	@ignore @property static MongoCollection collection() { return mongoAdapter.getCollection(containerName); }
	@ignore static @property string containerName() { return _containerName; }
	@optional static @property void containerName(string containerName) { _containerName = containerName; }
	@optional BsonObjectID _id;

	@ignore @property BsonObjectID id() { return _id; } 
	@optional @property void id(BsonObjectID id) { _id = id; } 
	@ignore @property bool isNew() { return !id.valid; }

	@property SysTime createdAt() {
		return id.timeStamp;
	}

	void ensureId() {
		if (!id.valid) {
			id = BsonObjectID.generate();
		}
	}

	static void ensureIndex(int[string] fieldOrders, IndexFlags flags = cast(IndexFlags)0) {
		mongoAdapter.ensureIndex(containerName, fieldOrders, flags);
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
		assert(mongodb.fullDatabaseName == "testdb_development");
		assert(mongodb.collectionPath("test") == "testdb_development.test");
		mongodb.registerModel!(PersistenceTestUser, "users");
		
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
		mongodb.registerModel!(PersistenceTestPerson, "people");
		
		assert(mongodb.fullDatabaseName == "testdb_development");
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

