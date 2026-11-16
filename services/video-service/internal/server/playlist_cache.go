package server

import (
	"container/list"
	"sync"
)

// playlistCache keeps playlists read from storage by key, at most maxEntries of them and maxBytes
// in total, dropping the least recently used first. The playlists of a version never change once
// written, so an entry is never stale. It is safe for concurrent use.
type playlistCache struct {
	maxEntries, maxBytes int

	mu    sync.Mutex
	bytes int
	// order holds *cacheEntry values, the most recently used first.
	order   *list.List
	entries map[string]*list.Element
}

type cacheEntry struct {
	key  string
	data []byte
}

func newPlaylistCache(maxEntries, maxBytes int) *playlistCache {
	return &playlistCache{maxEntries: maxEntries, maxBytes: maxBytes, order: list.New(), entries: map[string]*list.Element{}}
}

// get returns the playlist at key, and false when it is not cached. Callers must not change it.
func (c *playlistCache) get(key string) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[key]
	if !ok {
		return nil, false
	}
	c.order.MoveToFront(e)
	return e.Value.(*cacheEntry).data, true
}

// add caches data as the playlist at key; a playlist larger than maxBytes is not cached.
func (c *playlistCache) add(key string, data []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.entries[key]; ok || len(data) > c.maxBytes {
		return
	}
	c.entries[key] = c.order.PushFront(&cacheEntry{key: key, data: data})
	c.bytes += len(data)
	for c.order.Len() > c.maxEntries || c.bytes > c.maxBytes {
		oldest := c.order.Remove(c.order.Back()).(*cacheEntry)
		delete(c.entries, oldest.key)
		c.bytes -= len(oldest.data)
	}
}
