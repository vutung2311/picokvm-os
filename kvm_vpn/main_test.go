package main

import (
	"sync/atomic"
	"testing"
)

func BenchmarkWorkerPoolSubmit(b *testing.B) {
	pool := newWorkerPool(2, 65536)
	var count int64
	task := func() {
		atomic.AddInt64(&count, 1)
	}

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for !pool.Submit(task) {
		}
	}
}
