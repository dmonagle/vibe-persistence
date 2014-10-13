module persistence.base;

import vibe.data.serialization;
public import vibe.core.log;

interface ModelInterface {
	@property string idString();
	void setId(string id);
	void ensureId();

	bool beforeCreate();
	bool beforeUpdate();
	bool beforeSave();
	void afterSave();
	void afterCreate();
}

class PersistenceModel : ModelInterface {
	abstract @property string idString();
	abstract void setId(string id);
	abstract void ensureId();

	bool beforeCreate() { return true; }
	bool beforeUpdate() { return true; }
	bool beforeSave() { return true; }
	void afterSave() {}
	void afterCreate() {}
}

struct ModelMeta {
	string containerName;
	string type;
	bool cached;
	bool audit;
}

struct EmbeddedAttribute {
}

@property EmbeddedAttribute embedded() { return EmbeddedAttribute(); }

class PersistenceAdapter {
	protected {
		ModelMeta[string] _meta;
		string _applicationName;
		string _environment;
	}

	this(string name, string environment) {
		_applicationName = name;
		_environment = environment;
	}

	@property string fullName(string name = "") {
		assert(_applicationName.length);
		assert(_environment.length);

		auto returnName = _applicationName ~ "_" ~ _environment;
		if (name.length) returnName ~= "_" ~ name;

		return returnName;
	}

	/// This should be called by the derived adapter from a registerModel template. It should not be called directly.
	void registerPersistenceModel(M)(ModelMeta m) {
		assert(m.containerName.length, "You must specify a container name for model: " ~ M.stringof);
		logDebug("Model '%s' registered with adapter %s", M.stringof, typeof(this).stringof);
		if (!m.type.length) m.type = M.stringof;
		_meta[m.type] = m;
	}

	@property bool modelRegistered(M)() {
		return cast(bool)(M.stringof in _meta);
	}

	@property ModelMeta modelMeta(M)() {
		assert(modelRegistered!M, "Model " ~ M.stringof ~ " is not registered with Persistence Adapter");
		return _meta[M.stringof];
	}
}