module persistence.elasticsearch;

public import persistence.base;

import elasticsearch.client;
public import elasticsearch.parameters;
import elasticsearch.api.actions.base;
import elasticsearch.api.actions.indices;

import vibe.core.log;

import persistence.cache;

import vibe.inet.url;

class EsAdapter : PersistenceAdapter {
	private {
		Client _client;
		string[] _hosts;

		CacheContainer!Json _cache;
	}

	this(string applicationName, string environment, string[] hosts ...) {
		super(applicationName, environment);
		_hosts = hosts;
	}

	void registerModel(M)(ModelMeta m) {
		registerPersistenceModel!M(m);
	}

	@property Client client() {
		import vibe.core.log;

		if (!_client) {
			_client = new Client();
			foreach(host; _hosts) {
				auto url = URL.parse(host);
				_client.addHost(Host(
					url.host,
					url.port,
					url.schema,
					url.pathString,
					url.username,
					url.password
					)
				);
			}
		}
		return _client;
	}

	void ensureIndex(M)(string content, bool drop = false) {
		auto name = fullName(modelMeta!M.containerName);
		if (drop) {
			logInfo("Dropping Elasticsearch Index: '%s'", name);
			deleteIndex!M;
		}
		if (!_client.indexExists(name)) {
			_client.createIndex(name, content);
			logInfo("Creating Elasticsearch Index: '%s'", name);
		}
	}

	void deleteIndex(M)() {
		auto name = fullName(modelMeta!M.containerName);
		if (_client.indexExists(name)) {
			logInfo("Deleting Elasticsearch Index: '%s'", name);
			_client.deleteIndex(name);
		}
	}

	void index(M)(const ref Json model) {
		auto meta = modelMeta!M;
		client.index(fullName(meta.containerName), meta.type, model._id.to!string, model.toString());
	}

	void index(M)(M model) {
		static if (__traits(compiles, model.toIndexedJson)) {
			auto json = model.toIndexedJson;
		}
		else {
			auto json = model.serializeToJson;
		}

		index!M(json);
	}

	Json search(M)(string searchBody, Parameters params = Parameters()) {
		auto meta = modelMeta!M;

		params["body"] = searchBody;
		params["index"] = fullName(meta.containerName);
		if ("type" !in params)
			params["type"] = meta.type;
		else {
			// If the type is specified as blank, remove the type
			if (!params["type"].length) params.remove("type");
		}

		auto response = client.search(params);

		return response.jsonBody;
	}
}
