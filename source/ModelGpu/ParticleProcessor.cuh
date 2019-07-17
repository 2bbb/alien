#pragma once

#include "device_functions.h"
#include "sm_60_atomic_functions.h"

#include "CudaAccessTOs.cuh"
#include "Base.cuh"
#include "Physics.cuh"
#include "Map.cuh"

class ParticleProcessor
{
public:
	__inline__ __device__ void init_gridCall(SimulationData& data);

    __inline__ __device__ void processingMovement_gridCall();
    __inline__ __device__ void updateMap_gridCall();
    __inline__ __device__ void processingCollision_gridCall();
    __inline__ __device__ void processingTransformation_gridCall();
	__inline__ __device__ void processingDataCopy_gridCall();

private:

	SimulationData* _data;

    PartitionData _particleBlock;
};


/************************************************************************/
/* Implementation                                                       */
/************************************************************************/
__inline__ __device__ void ParticleProcessor::init_gridCall(SimulationData & data)
{
    _data = &data;

    _particleBlock = calcPartition(
        data.entities.particlePointers.getNumEntries(), threadIdx.x + blockIdx.x * blockDim.x, blockDim.x * gridDim.x);
}

__inline__ __device__ void ParticleProcessor::processingMovement_gridCall()
{
    for (int particleIndex = _particleBlock.startIndex; particleIndex <= _particleBlock.endIndex; ++particleIndex) {
        Particle* particle = _data->entities.particlePointers.getEntireArray()[particleIndex];
        particle->absPos = particle->absPos + particle->vel;
        _data->particleMap.mapPosCorrection(particle->absPos);
    }
}

__inline__ __device__ void ParticleProcessor::updateMap_gridCall()
{
    Particle** particles = &_data->entities.particlePointers.at(_particleBlock.startIndex);
    _data->particleMap.set_blockCall(_particleBlock.numElements(), particles);
}

__inline__ __device__ void ParticleProcessor::processingCollision_gridCall()
{
    for (int particleIndex = _particleBlock.startIndex; particleIndex <= _particleBlock.endIndex; ++particleIndex) {
        Particle* particle = _data->entities.particlePointers.getEntireArray()[particleIndex];
        Particle* otherParticle = _data->particleMap.get(particle->absPos);
        if (otherParticle && otherParticle != particle) {
            if (particle->alive && otherParticle->alive) {

                DoubleLock lock;
                lock.init(&particle->locked, &otherParticle->locked);
                lock.tryLock();
                if (!lock.isLocked()) {
                    continue;
                }

                float factor1 = particle->energy / (particle->energy + otherParticle->energy);
                float factor2 = 1.0f - factor1;
                particle->vel = particle->vel * factor1 + otherParticle->vel * factor2;
                atomicAdd(&particle->energy, otherParticle->energy);
                atomicAdd(&otherParticle->energy, -otherParticle->energy);
                otherParticle->alive = false;

                lock.releaseLock();
            }
        }
    }
}

__inline__ __device__ void ParticleProcessor::processingTransformation_gridCall()
{
    for (int particleIndex = _particleBlock.startIndex; particleIndex <= _particleBlock.endIndex; ++particleIndex) {
        Particle* particle = _data->entities.particlePointers.getEntireArray()[particleIndex];
        auto innerEnergy = particle->energy - Physics::linearKineticEnergy(1.0f / cudaSimulationParameters.cellMass_Reciprocal, particle->vel);
        if (innerEnergy >= cudaSimulationParameters.cellMinEnergy) {
            if (_data->numberGen.random() < cudaSimulationParameters.cellTransformationProb) {
                EntityFactory factory;
                factory.init(_data);
                factory.createClusterWithRandomCell(innerEnergy, particle->absPos, particle->vel);
                particle->alive = false;
            }
        }
    }
}

__inline__ __device__ void ParticleProcessor::processingDataCopy_gridCall()
{
	for (int particleIndex = _particleBlock.startIndex; particleIndex <= _particleBlock.endIndex; ++particleIndex) {
		auto& particle = _data->entities.particlePointers.at(particleIndex);
		if (!particle->alive) {
            particle = nullptr;
			continue;
		}

        if (auto cell = _data->cellMap.get(particle->absPos)) {
			if (cell->alive) {
				atomicAdd(&cell->energy, particle->energy);
                particle = nullptr;
                continue;
			}
		}
	}
}
