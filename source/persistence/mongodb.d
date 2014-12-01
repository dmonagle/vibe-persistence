module persistence.mongodb;

import persistence.cache;
public import persistence.exceptions;

public import vibe.db.mongo.mongo;
public import vibe.data.bson;
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

	void registerModel(M)(ModelMeta m) {
		registerPersistenceModel!M(m);
		M.mongoAdapter = this;
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

	/// Executes the given query within the container for the model and calls the delegate for each match
	void find(ModelType, Q)(Q query, scope void delegate(Bson model) pred = null, uint limit = 0) {
		import std.array;
		import std.algorithm;

		auto collection = getCollection!ModelType;
		query._type = modelMeta!ModelType.type;
		
		auto cursor = collection.find(query);
		if (limit) cursor.limit(limit);

		while (!cursor.empty) {
			auto bsonModel = cursor.front;
			if (pred) pred(bsonModel);
			cursor.popFront;
		}
	}

	/// Returns an array of Bson models matching the list of ids given
	Bson[] find(ModelType, string key = "_id", IdType)(IdType[] ids ...) {
		import std.array;
		import std.algorithm;
		
		Bson[] models;
		auto query = serializeToBson([key: ["$in": ids]]);

		this.find!ModelType(query, 
			(model) {
				// Add to cache here
				models ~= model;
			}
		);

		return models;
	}

	/// Returns a single Bson model matching the given id
	Bson find(ModelType, string key = "_id", IdType)(IdType id) {
		import std.conv;
		
		auto models = find!(ModelType, key, IdType)([id]);
		if (models.length) return models[0];
		return Bson(null);
	}
	
	/// Executes the the given query on the models container and calls the delegate with the deserialised model for each match.
	void findModel(ModelType, Q)(Q query, scope void delegate(ModelType model) pred = null, uint limit = 0) {
		import std.array;
		import std.algorithm;

		this.find!ModelType(query, 
			(bsonModel) {
				ModelType model;
				deserializeBson(model, bsonModel);
				if (pred) pred(model);
			}
		, limit);
	}

	/// Returns an array of deserialized models matching the list of ids given
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

	/// Returns a single deserialized model matching the given id
	ModelType findModel(ModelType, string key = "_id", IdType)(IdType id) {
		import std.conv;
		
		auto models = findModel!(ModelType, key, IdType)([id]);
		if (models.length) return models[0];
		static if(is(ModelType == class)) return null;
		else throw new NoModelForIdException("Could not find model with id " ~ to!string(id) ~ " in " ~ modelMeta!ModelType.containerName);
	}
	
	bool save(M)(ref M model) {
		auto collection = getCollection(modelMeta!M.containerName);

		Bson bsonModel;

		ensureEmbeddedIds(model);
		if(model.isNew) {
			model.ensureId();
			bsonModel = serializeToBson(model);
			logDebugV("Inserting into collection %s: %s", modelMeta!M.containerName, bsonModel.toString);
			collection.insert(model);
		} else {
			bsonModel = serializeToBson(model);
			logDebugV("Upserting %s into collection %s: %s", model.id.toString, modelMeta!M.containerName, bsonModel.toString);
			collection.update(["_id": model.id], bsonModel, UpdateFlags.Upsert);
		}
		
		_cache.addToCache(bsonModel._id.toString(), bsonModel);
		
		return true;
	}

	bool remove(M)(ref M model) {
		auto collection = getCollection(modelMeta!M.containerName);
		collection.remove(["_id": model.id]);
		return true;
	}

	void ensureEmbeddedIds(M)(ref M model) {
		import persistence.traits;
		import std.traits;

		foreach (memberName; __traits(allMembers, M)) {
			//static if (isRWPlainField!(M, memberName) || isRWField!(M, memberName)) {
			static if (is(typeof(__traits(getMember, model, memberName)))) {
				static if (__traits(getProtection, __traits(getMember, model, memberName)) == "public") {
					alias member = Tuple!(__traits(getMember, M, memberName));
					alias embeddedUDA = findFirstUDA!(EmbeddedAttribute, member);
					static if (embeddedUDA.found) {
						auto embeddedModel = __traits(getMember, model, memberName);
						static if (isArray!(typeof(embeddedModel))) {
							foreach(m; embeddedModel) ensureEmbeddedIds(m);
						} else {
							if (embeddedModel) {
								embeddedModel.ensureId();
								ensureEmbeddedIds(embeddedModel);
							}
						}
					}
				}
			}
		}
	}
}

mixin template MongoModel(ModelType, string cName = "") {
	private {
		static MongoAdapter _mongoAdapter;
	}

	@optional BsonObjectID _id;

	// Dummy setter so that _type will be serialized
	@optional @property void _type(string value) {}
	@property const string _type() { return ModelType.stringof; }

	@ignore @property BsonObjectID id() { return _id; } 
	@optional @property void id(BsonObjectID id) { _id = id; } 
	@ignore @property bool isNew() { return !id.valid; }

	@ignore static @property MongoAdapter mongoAdapter() { return _mongoAdapter; }
	@optional static @property void mongoAdapter(MongoAdapter ma) { _mongoAdapter = ma; }

	@property SysTime createdAt() {
		return id.timeStamp;
	}
	
	void ensureId() {
		if (!id.valid) {
			id = BsonObjectID.generate();
		}
	}

	static ModelType findModel(string key = "_id", IdType)(IdType id) {
		return _mongoAdapter.findModel!(ModelType, key)(id);
	}

	bool save()() {
		return _mongoAdapter.save(this);
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

		assert(mongodb.find!PersistenceTestPerson("000000000000000000000000").type == Bson.Type.null_);
	}
}

import std.typecons;

bool mongoReferenceIsNull(T)(T reference) {
	import std.stdio;

	static if (is(T == class)) 
		return reference ? false : true;
	else static if (__traits(compiles, reference.isNull)) 
		return reference.isNull;
	else 
		return false;
}

unittest {
	struct TestStruct {
	}
	class TestClass {
	}

	TestClass testClass;

	assert(mongoReferenceIsNull(testClass));
	testClass = new TestClass;
	assert(!mongoReferenceIsNull(testClass));

	TestStruct testStruct;
	assert(!mongoReferenceIsNull(testStruct));

	Nullable!TestStruct testStructNullable;
	assert(mongoReferenceIsNull(testStructNullable));
}

mixin template BelongsTo(T, string name, string attributeName, string key = "_id") {
	import std.string;
	
	static if (!is(T == class)) {
		static assert(is(T : Nullable), "Belongs to type, " ~ T.stringof ~ ", must be a class or Nullable!");
	}
	
	// Create the private variable
	mixin (format("private %s _%s;", T.stringof, name));
	
	static immutable string propertyGetterCode = format(`
		@ignore @property %1$s %2$s() {
			// Return the private variable if it is already set
			if (_%2$s) return _%2$s;
		
			if (!mongoReferenceIsNull(%3$s))
				_%2$s = %1$s.findModel!"%4$s"(%3$s);
			
			return _%2$s;
		}
	`, T.stringof, name, attributeName, key);
	
	mixin(propertyGetterCode);
}

