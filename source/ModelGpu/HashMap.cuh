#pragma once

#include "HashSet.cuh"
#include "Array.cuh"

template <typename Key, typename Value, typename Hash = HashFunctor<Key>>
class HashMap
{
public:
    __device__ __inline__ void init_blockCall(int size, ArrayController& arrays)
    {
        __shared__ Entry* entries;
        if (0 == threadIdx.x) {
            entries = arrays.getArray<Entry>(size);
        }
        __syncthreads();

        _size = size;
        _entries = entries;

        auto const threadBlock = calcPartition(size, threadIdx.x, blockDim.x);
        for (int i = threadBlock.startIndex; i <= threadBlock.endIndex; ++i) {
            _entries[i].setFree(0);
            _entries[i].initLock();
            _entries[i]._who = -1;
        }
        __syncthreads();
    }

    __device__ __inline__ void insertOrAssign(Key const& key, Value const& value)
    {
        int index = _hash(key) % _size;
        int wasFree;
        int dummy = 0;
        do {
            if (++dummy == _size) {
                printf("OHHHH insertOrAssign!: %d\n", _size); while (true) {}
            }
            auto& entry = _entries[index];
            entry.getLock(1);
            wasFree = entry.setFree(1);
            if (1 == wasFree) {
                if (entry.getKey() == key) {
                    entry.setValue(value);
                    entry.releaseLock();
                    return;
                }
                entry.releaseLock();
                index = (++index) % _size;
            }
        } while (1 == wasFree);

        auto& newEntry = _entries[index];
        newEntry.setKey(key);
        newEntry.setValue(value);
        newEntry.releaseLock();
    }

    __device__ __inline__ bool contains(Key const& key) const
    {
        int index = _hash(key) % _size;
        for (int i = 0; i < _size; ++i, index = (++index) % _size) {
            auto& entry = _entries[index];
            entry.getLock(2);
            if (0 == entry.getFree()) {
                entry.releaseLock();
                return false;
            }
            if (entry.getKey() == key) {
                entry.releaseLock();
                return true;
            }
            entry.releaseLock();
        }
        return false;
    }

    __device__ __inline__ Value at(Key const& key)
    {
        int index = _hash(key) % _size;
        int dummy = 0;
        do {
            if (++dummy == _size) {
                printf("OHHHH at!: %d\n", _size); while (true) {}
            }
            auto& entry = _entries[index];
            entry.getLock(3);
            if (0 == entry.getFree()) {
                entry.releaseLock();
                return Value();
            }
            if (entry.getKey() == key) {
                auto result = entry.getValue();
                entry.releaseLock();
                return result;
            }
            entry.releaseLock();
            index = (++index) % _size;
        }
        while (true);
    }

private:
    Hash _hash;

    class Entry
    {
    public:
        __device__ __inline__ int setFree(int value)
        {
            int origValue = _free;
            _free = value;
            return origValue;
//            return atomicExch_block(&_free, value);
        }
        __device__ __inline__ int getFree()
        {
            return _free;
//            return atomicAdd_block(&_free, 0);
        }

        __device__ __inline__ void setValue(Value const& value)
        {
            _value = value;
        }
        __device__ __inline__ Value getValue()
        {
            return _value;
        }

        __device__ __inline__ void setKey(Key const& value)
        {
            _key = value;
        }
        __device__ __inline__ Key getKey()
        {
            return _key;
        }

        __device__ __inline__ void initLock()
        {
            atomicExch_block(&_locked, 0);
        }

        __device__ __inline__ bool tryLock()
        {
            return 0 == atomicExch(&_locked, 1);
        }

        __device__ __inline__ void getLock(int parameter)
        {
            int i = 0;
            while (1 == atomicExch_block(&_locked, 1)) {

                if (++i == 100) {
                    printf("wait: %d\n", atomicAdd_block(&_who,0));
                }

            }
            _who = parameter;
            __threadfence_block();
        }

        __device__ __inline__ void releaseLock()
        {
            _who = 0;
            __threadfence_block();
            atomicExch_block(&_locked, 0);
        }

        int _who;
    private:
        int _free;   //0 = free, 1 = used
        int _locked;	//0 = unlocked, 1 = locked
        Value _value;
        Key _key;
    };
    int _size;
    Entry* _entries;
};
