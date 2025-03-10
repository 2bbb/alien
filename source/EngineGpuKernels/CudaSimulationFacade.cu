#include "CudaSimulationFacade.cuh"

#include <functional>
#include <iostream>
#include <list>

#include <cuda_runtime.h>
#include <cuda_gl_interop.h>

#include <device_launch_parameters.h>
#include <cuda/helper_cuda.h>

#include "Base/Exceptions.h"
#include "EngineInterface/InspectedEntityIds.h"
#include "EngineInterface/SimulationParameters.h"
#include "EngineInterface/GpuSettings.h"

#include "Base/LoggingService.h"
#include "DataAccessKernels.cuh"
#include "AccessTOs.cuh"
#include "Base.cuh"
#include "GarbageCollectorKernels.cuh"
#include "ConstantMemory.cuh"
#include "CudaMemoryManager.cuh"
#include "CudaMonitorData.cuh"
#include "Entities.cuh"
#include "Map.cuh"
#include "MonitorKernels.cuh"
#include "EditKernels.cuh"
#include "RenderingKernels.cuh"
#include "SimulationData.cuh"
#include "SimulationKernelsLauncher.cuh"
#include "DataAccessKernelsLauncher.cuh"
#include "RenderingKernelsLauncher.cuh"
#include "EditKernelsLauncher.cuh"
#include "MonitorKernelsLauncher.cuh"
#include "SimulationResult.cuh"
#include "SelectionResult.cuh"
#include "RenderingData.cuh"

namespace
{
    class CudaInitializer
    {
    public:
        static void init() { [[maybe_unused]] static CudaInitializer instance; }

        CudaInitializer()
        {
            int deviceNumber = getDeviceNumberOfHighestComputeCapability();

            auto result = cudaSetDevice(deviceNumber);
            if (result != cudaSuccess) {
                throw SystemRequirementNotMetException("CUDA device could not be initialized.");
            }

            std::stringstream stream;
            stream << "device " << deviceNumber << " is set";
            log(Priority::Important, stream.str());
        }

        ~CudaInitializer() { cudaDeviceReset(); }

    private:
        int getDeviceNumberOfHighestComputeCapability()
        {
            int result = 0;
            int numberOfDevices;
            CHECK_FOR_CUDA_ERROR(cudaGetDeviceCount(&numberOfDevices));
            if (numberOfDevices < 1) {
                throw SystemRequirementNotMetException("No CUDA device found.");
            }
            {
                std::stringstream stream;
                if (1 == numberOfDevices) {
                    stream << "1 CUDA device found";
                } else {
                    stream << numberOfDevices << " CUDA devices found";
                }
                log(Priority::Important, stream.str());
            }

            int highestComputeCapability = 0;
            for (int deviceNumber = 0; deviceNumber < numberOfDevices; ++deviceNumber) {
                cudaDeviceProp prop;
                CHECK_FOR_CUDA_ERROR(cudaGetDeviceProperties(&prop, deviceNumber));

                std::stringstream stream;
                stream << "device " << deviceNumber << ": " << prop.name << " with compute capability " << prop.major
                       << "." << prop.minor;
                log(Priority::Important, stream.str());

                int computeCapability = prop.major * 100 + prop.minor;
                if (computeCapability > highestComputeCapability) {
                    result = deviceNumber;
                    highestComputeCapability = computeCapability;
                }
            }
            if (highestComputeCapability < 502) {
                throw SystemRequirementNotMetException(
                    "No CUDA device with compute capability of 5.2 or higher found.");
            }

            return result;
        }
    };
}

void _CudaSimulationFacade::initCuda()
{
    CudaInitializer::init();
}

_CudaSimulationFacade::_CudaSimulationFacade(uint64_t timestep, Settings const& settings)
{
    CHECK_FOR_CUDA_ERROR(cudaGetLastError());

    setSimulationParameters(settings.simulationParameters);
    setSimulationParametersSpots(settings.simulationParametersSpots);
    setGpuConstants(settings.gpuSettings);
    setFlowFieldSettings(settings.flowFieldSettings);

    log(Priority::Important, "initialize simulation");

    _currentTimestep.store(timestep);
    _cudaSimulationData = std::make_shared<SimulationData>();
    _cudaRenderingData = std::make_shared<RenderingData>();
    _cudaSimulationResult = std::make_shared<SimulationResult>();
    _cudaSelectionResult = std::make_shared<SelectionResult>();
    _cudaAccessTO = std::make_shared<DataAccessTO>();
    _cudaMonitorData = std::make_shared<CudaMonitorData>();

    _cudaSimulationData->init({settings.generalSettings.worldSizeX, settings.generalSettings.worldSizeY});
    _cudaRenderingData->init();
    _cudaMonitorData->init();
    _cudaSimulationResult->init();
    _cudaSelectionResult->init();

    _simulationKernels = std::make_shared<_SimulationKernelsLauncher>();
    _dataAccessKernels = std::make_shared<_DataAccessKernelsLauncher>();
    _garbageCollectorKernels = std::make_shared<_GarbageCollectorKernelsLauncher>();
    _renderingKernels = std::make_shared<_RenderingKernelsLauncher>();
    _editKernels = std::make_shared<_EditKernelsLauncher>();
    _monitorKernels = std::make_shared<_MonitorKernelsLauncher>();

    CudaMemoryManager::getInstance().acquireMemory<int>(1, _cudaAccessTO->numCells);
    CudaMemoryManager::getInstance().acquireMemory<int>(1, _cudaAccessTO->numParticles);
    CudaMemoryManager::getInstance().acquireMemory<int>(1, _cudaAccessTO->numTokens);
    CudaMemoryManager::getInstance().acquireMemory<int>(1, _cudaAccessTO->numStringBytes);

    //default array sizes for empty simulation (will be resized later if not sufficient)
    resizeArrays({100000, 100000, 10000});
}

_CudaSimulationFacade::~_CudaSimulationFacade()
{
    _cudaSimulationData->free();
    _cudaRenderingData->free();
    _cudaMonitorData->free();
    _cudaSimulationResult->free();
    _cudaSelectionResult->free();

    CudaMemoryManager::getInstance().freeMemory(_cudaAccessTO->cells);
    CudaMemoryManager::getInstance().freeMemory(_cudaAccessTO->particles);
    CudaMemoryManager::getInstance().freeMemory(_cudaAccessTO->tokens);
    CudaMemoryManager::getInstance().freeMemory(_cudaAccessTO->stringBytes);
    CudaMemoryManager::getInstance().freeMemory(_cudaAccessTO->numCells);
    CudaMemoryManager::getInstance().freeMemory(_cudaAccessTO->numParticles);
    CudaMemoryManager::getInstance().freeMemory(_cudaAccessTO->numTokens);
    CudaMemoryManager::getInstance().freeMemory(_cudaAccessTO->numStringBytes);

    log(Priority::Important, "close simulation");
}

void* _CudaSimulationFacade::registerImageResource(GLuint image)
{
    cudaGraphicsResource* cudaResource;

    CHECK_FOR_CUDA_ERROR(
        cudaGraphicsGLRegisterImage(&cudaResource, image, GL_TEXTURE_2D, cudaGraphicsMapFlagsReadOnly));

    return reinterpret_cast<void*>(cudaResource);
}

void _CudaSimulationFacade::calcTimestep()
{
    _simulationKernels->calcTimestep(_settings, *_cudaSimulationData, *_cudaSimulationResult);
    syncAndCheck();

    automaticResizeArrays();
    ++_currentTimestep;
}

void _CudaSimulationFacade::drawVectorGraphics(
    float2 const& rectUpperLeft,
    float2 const& rectLowerRight,
    void* cudaResource,
    int2 const& imageSize,
    double zoom)
{
    auto cudaResourceImpl = reinterpret_cast<cudaGraphicsResource*>(cudaResource);
    CHECK_FOR_CUDA_ERROR(cudaGraphicsMapResources(1, &cudaResourceImpl));

    cudaArray* mappedArray;
    CHECK_FOR_CUDA_ERROR(cudaGraphicsSubResourceGetMappedArray(&mappedArray, cudaResourceImpl, 0, 0));

    _cudaRenderingData->resizeImageIfNecessary(imageSize);

    _renderingKernels->drawImage(_settings.gpuSettings, rectUpperLeft, rectLowerRight, imageSize, static_cast<float>(zoom), *_cudaSimulationData, *_cudaRenderingData);
    syncAndCheck();

    const size_t widthBytes = sizeof(uint64_t) * imageSize.x;
    CHECK_FOR_CUDA_ERROR(cudaMemcpy2DToArray(
        mappedArray,
        0,
        0,
        _cudaRenderingData->imageData,
        widthBytes,
        widthBytes,
        imageSize.y,
        cudaMemcpyDeviceToDevice));

    CHECK_FOR_CUDA_ERROR(cudaGraphicsUnmapResources(1, &cudaResourceImpl));
}

void _CudaSimulationFacade::getSimulationData(
    int2 const& rectUpperLeft,
    int2 const& rectLowerRight,
    DataAccessTO const& dataTO)
{
    _dataAccessKernels->getData(_settings.gpuSettings, *_cudaSimulationData, rectUpperLeft, rectLowerRight, *_cudaAccessTO);
    syncAndCheck();

    copyDataTOtoHost(dataTO);
}

void _CudaSimulationFacade::getSelectedSimulationData(bool includeClusters, DataAccessTO const& dataTO)
{
    _dataAccessKernels->getSelectedData(_settings.gpuSettings, *_cudaSimulationData, includeClusters, *_cudaAccessTO);
    syncAndCheck();

    copyDataTOtoHost(dataTO);
}

void _CudaSimulationFacade::getInspectedSimulationData(std::vector<uint64_t> entityIds, DataAccessTO const& dataTO)
{
    InspectedEntityIds ids;
    if (entityIds.size() > Const::MaxInspectedEntities) {
        return;
    }
    for (int i = 0; i < entityIds.size(); ++i) {
        ids.values[i] = entityIds.at(i);
    }
    if (entityIds.size() < Const::MaxInspectedEntities) {
        ids.values[entityIds.size()] = 0;
    }
    _dataAccessKernels->getInspectedData(_settings.gpuSettings, *_cudaSimulationData, ids, *_cudaAccessTO);
    syncAndCheck();
    copyDataTOtoHost(dataTO);
}

void _CudaSimulationFacade::getOverlayData(int2 const& rectUpperLeft, int2 const& rectLowerRight, DataAccessTO const& dataTO)
{
    _dataAccessKernels->getOverlayData(_settings.gpuSettings, *_cudaSimulationData, rectUpperLeft, rectLowerRight, *_cudaAccessTO);
    syncAndCheck();

    copyToHost(dataTO.numCells, _cudaAccessTO->numCells);
    copyToHost(dataTO.numParticles, _cudaAccessTO->numParticles);
    copyToHost(dataTO.cells, _cudaAccessTO->cells, *dataTO.numCells);
    copyToHost(dataTO.particles, _cudaAccessTO->particles, *dataTO.numParticles);
}

void _CudaSimulationFacade::addAndSelectSimulationData(DataAccessTO const& dataTO)
{
    copyDataTOtoDevice(dataTO);
    _editKernels->removeSelection(_settings.gpuSettings, *_cudaSimulationData);
    _dataAccessKernels->addData(_settings.gpuSettings, *_cudaSimulationData, *_cudaAccessTO, true, true);
    syncAndCheck();
}

void _CudaSimulationFacade::setSimulationData(DataAccessTO const& dataTO)
{
    copyDataTOtoDevice(dataTO);
    _dataAccessKernels->clearData(_settings.gpuSettings, *_cudaSimulationData);
    _dataAccessKernels->addData(_settings.gpuSettings, *_cudaSimulationData, *_cudaAccessTO, false, false);
    syncAndCheck();
}

void _CudaSimulationFacade::removeSelectedEntities(bool includeClusters)
{
    _editKernels->removeSelectedEntities(_settings.gpuSettings, *_cudaSimulationData, includeClusters);
    syncAndCheck();
}

void _CudaSimulationFacade::relaxSelectedEntities(bool includeClusters)
{
    _editKernels->relaxSelectedEntities(_settings.gpuSettings, *_cudaSimulationData, includeClusters);
    syncAndCheck();
}

void _CudaSimulationFacade::uniformVelocitiesForSelectedEntities(bool includeClusters)
{
    _editKernels->uniformVelocitiesForSelectedEntities(_settings.gpuSettings, *_cudaSimulationData, includeClusters);
    syncAndCheck();
}

void _CudaSimulationFacade::makeSticky(bool includeClusters)
{
    _editKernels->makeSticky(_settings.gpuSettings, *_cudaSimulationData, includeClusters);
    syncAndCheck();
}

void _CudaSimulationFacade::removeStickiness(bool includeClusters)
{
    _editKernels->removeStickiness(_settings.gpuSettings, *_cudaSimulationData, includeClusters);
    syncAndCheck();
}

void _CudaSimulationFacade::setBarrier(bool value, bool includeClusters)
{
    _editKernels->setBarrier(_settings.gpuSettings, *_cudaSimulationData, value, includeClusters);
    syncAndCheck();
}

void _CudaSimulationFacade::changeInspectedSimulationData(DataAccessTO const& changeDataTO)
{
    copyDataTOtoDevice(changeDataTO);
    _editKernels->changeSimulationData(_settings.gpuSettings, *_cudaSimulationData, *_cudaAccessTO);
    syncAndCheck();
}

void _CudaSimulationFacade::applyForce(ApplyForceData const& applyData)
{
    _editKernels->applyForce(_settings.gpuSettings, *_cudaSimulationData, applyData);
    syncAndCheck();
}

void _CudaSimulationFacade::switchSelection(PointSelectionData const& pointData)
{
    _editKernels->switchSelection(_settings.gpuSettings, *_cudaSimulationData, pointData);
    syncAndCheck();
}

void _CudaSimulationFacade::swapSelection(PointSelectionData const& pointData)
{
    _editKernels->swapSelection(_settings.gpuSettings, *_cudaSimulationData, pointData);
    syncAndCheck();
}

void _CudaSimulationFacade::setSelection(AreaSelectionData const& selectionData)
{
    _editKernels->setSelection(_settings.gpuSettings, *_cudaSimulationData, selectionData);
}

 SelectionShallowData _CudaSimulationFacade::getSelectionShallowData()
{
    _editKernels->getSelectionShallowData(_settings.gpuSettings, *_cudaSimulationData, *_cudaSelectionResult);
    syncAndCheck();
    return _cudaSelectionResult->getSelectionShallowData();
}

void _CudaSimulationFacade::shallowUpdateSelectedEntities(ShallowUpdateSelectionData const& shallowUpdateData)
{
    _editKernels->shallowUpdateSelectedEntities(_settings.gpuSettings, *_cudaSimulationData, shallowUpdateData);
    syncAndCheck();
}

void _CudaSimulationFacade::removeSelection()
{
    _editKernels->removeSelection(_settings.gpuSettings, *_cudaSimulationData);
    syncAndCheck();
}

void _CudaSimulationFacade::updateSelection()
{
    _editKernels->updateSelection(_settings.gpuSettings, *_cudaSimulationData);
    syncAndCheck();
}

void _CudaSimulationFacade::colorSelectedEntities(unsigned char color, bool includeClusters)
{
    _editKernels->colorSelectedCells(_settings.gpuSettings, *_cudaSimulationData, color, includeClusters);
    syncAndCheck();
}

void _CudaSimulationFacade::reconnectSelectedEntities()
{
    _editKernels->reconnectSelectedEntities(_settings.gpuSettings, *_cudaSimulationData);
    syncAndCheck();
}

void _CudaSimulationFacade::setGpuConstants(GpuSettings const& gpuConstants)
{
    _settings.gpuSettings = gpuConstants;

    CHECK_FOR_CUDA_ERROR(
        cudaMemcpyToSymbol(cudaThreadSettings, &gpuConstants, sizeof(GpuSettings), 0, cudaMemcpyHostToDevice));
}

auto _CudaSimulationFacade::getArraySizes() const -> ArraySizes
{
    return {
        _cudaSimulationData->entities.cells.getSize_host(),
        _cudaSimulationData->entities.particles.getSize_host(),
        _cudaSimulationData->entities.tokens.getSize_host()};
}

MonitorData _CudaSimulationFacade::getMonitorData()
{
    _monitorKernels->getMonitorData(_settings.gpuSettings, *_cudaSimulationData, *_cudaMonitorData);
    syncAndCheck();
    
    MonitorData result;
    auto monitorData = _cudaMonitorData->getMonitorData(getCurrentTimestep());
    result.timeStep = monitorData.timeStep;
    for (int i = 0; i < 7; ++i) {
        result.numCellsByColor[i] = monitorData.numCellsByColor[i];
    }
    result.numConnections = monitorData.numConnections;
    result.numParticles = monitorData.numParticles;
    result.numTokens = monitorData.numTokens;
    result.totalInternalEnergy = monitorData.totalInternalEnergy;

    auto processStatistics = _cudaSimulationResult->getProcessMonitorData();
    result.numCreatedCells = processStatistics.createdCells;
    result.numSuccessfulAttacks = processStatistics.sucessfulAttacks;
    result.numFailedAttacks = processStatistics.failedAttacks;
    result.numMuscleActivities = processStatistics.muscleActivities;
    return result;
}

uint64_t _CudaSimulationFacade::getCurrentTimestep() const
{
    return _currentTimestep.load();
}

void _CudaSimulationFacade::setCurrentTimestep(uint64_t timestep)
{
    _currentTimestep.store(timestep);
}

void _CudaSimulationFacade::setSimulationParameters(SimulationParameters const& parameters)
{
    _settings.simulationParameters = parameters;
    CHECK_FOR_CUDA_ERROR(cudaMemcpyToSymbol(cudaSimulationParameters, &parameters, sizeof(SimulationParameters), 0, cudaMemcpyHostToDevice));
}

void _CudaSimulationFacade::setSimulationParametersSpots(SimulationParametersSpots const& spots)
{
    _settings.simulationParametersSpots = spots;
    CHECK_FOR_CUDA_ERROR(cudaMemcpyToSymbol(
        cudaSimulationParametersSpots, &spots, sizeof(SimulationParametersSpots), 0, cudaMemcpyHostToDevice));
}

void _CudaSimulationFacade::setFlowFieldSettings(FlowFieldSettings const& settings)
{
    CHECK_FOR_CUDA_ERROR(
        cudaMemcpyToSymbol(cudaFlowFieldSettings, &settings, sizeof(FlowFieldSettings), 0, cudaMemcpyHostToDevice));

    _settings.flowFieldSettings = settings;
}


void _CudaSimulationFacade::clear()
{
    _dataAccessKernels->clearData(_settings.gpuSettings, *_cudaSimulationData);
    syncAndCheck();
}

void _CudaSimulationFacade::resizeArraysIfNecessary(ArraySizes const& additionals)
{
    if (_cudaSimulationData->shouldResize(
            additionals.cellArraySize, additionals.particleArraySize, additionals.tokenArraySize)) {
        resizeArrays(additionals);
    }
}

void _CudaSimulationFacade::syncAndCheck()
{
    cudaDeviceSynchronize();
    CHECK_FOR_CUDA_ERROR(cudaGetLastError());
}

void _CudaSimulationFacade::copyDataTOtoDevice(DataAccessTO const& dataTO)
{
    copyToDevice(_cudaAccessTO->numCells, dataTO.numCells);
    copyToDevice(_cudaAccessTO->numParticles, dataTO.numParticles);
    copyToDevice(_cudaAccessTO->numTokens, dataTO.numTokens);
    copyToDevice(_cudaAccessTO->numStringBytes, dataTO.numStringBytes);

    copyToDevice(_cudaAccessTO->cells, dataTO.cells, *dataTO.numCells);
    copyToDevice(_cudaAccessTO->particles, dataTO.particles, *dataTO.numParticles);
    copyToDevice(_cudaAccessTO->tokens, dataTO.tokens, *dataTO.numTokens);
    copyToDevice(_cudaAccessTO->stringBytes, dataTO.stringBytes, *dataTO.numStringBytes);
}

void _CudaSimulationFacade::copyDataTOtoHost(DataAccessTO const& dataTO)
{
    copyToHost(dataTO.numCells, _cudaAccessTO->numCells);
    copyToHost(dataTO.numParticles, _cudaAccessTO->numParticles);
    copyToHost(dataTO.numTokens, _cudaAccessTO->numTokens);
    copyToHost(dataTO.numStringBytes, _cudaAccessTO->numStringBytes);

    copyToHost(dataTO.cells, _cudaAccessTO->cells, *dataTO.numCells);
    copyToHost(dataTO.particles, _cudaAccessTO->particles, *dataTO.numParticles);
    copyToHost(dataTO.tokens, _cudaAccessTO->tokens, *dataTO.numTokens);
    copyToHost(dataTO.stringBytes, _cudaAccessTO->stringBytes, *dataTO.numStringBytes);
}

void _CudaSimulationFacade::automaticResizeArrays()
{
    //make check after every 10th time step
    if (_currentTimestep.load() % 10 == 0) {
        if (_cudaSimulationResult->isArrayResizeNeeded()) {
            resizeArrays({0, 0, 0});
        }
    }
}

void _CudaSimulationFacade::resizeArrays(ArraySizes const& additionals)
{
    log(Priority::Important, "resize arrays");

    _cudaSimulationData->resizeEntitiesForCleanup(
        additionals.cellArraySize, additionals.particleArraySize, additionals.tokenArraySize);
    if (!_cudaSimulationData->isEmpty()) {
        _garbageCollectorKernels->copyArrays(_settings.gpuSettings, *_cudaSimulationData);
        syncAndCheck();

        _cudaSimulationData->resizeRemainings();

        _garbageCollectorKernels->swapArrays(_settings.gpuSettings, *_cudaSimulationData);
        syncAndCheck();
    } else {
        _cudaSimulationData->resizeRemainings();
    }

    CudaMemoryManager::getInstance().freeMemory(_cudaAccessTO->cells);
    CudaMemoryManager::getInstance().freeMemory(_cudaAccessTO->particles);
    CudaMemoryManager::getInstance().freeMemory(_cudaAccessTO->tokens);
    CudaMemoryManager::getInstance().freeMemory(_cudaAccessTO->stringBytes);

    auto cellArraySize = _cudaSimulationData->entities.cells.getSize_host();
    auto tokenArraySize = _cudaSimulationData->entities.tokens.getSize_host();
    CudaMemoryManager::getInstance().acquireMemory<CellAccessTO>(cellArraySize, _cudaAccessTO->cells);
    CudaMemoryManager::getInstance().acquireMemory<ParticleAccessTO>(cellArraySize, _cudaAccessTO->particles);
    CudaMemoryManager::getInstance().acquireMemory<TokenAccessTO>(tokenArraySize, _cudaAccessTO->tokens);
    CudaMemoryManager::getInstance().acquireMemory<char>(MAX_STRING_BYTES, _cudaAccessTO->stringBytes);

    CHECK_FOR_CUDA_ERROR(cudaGetLastError());

    log(Priority::Unimportant, "cell array size: " + std::to_string(cellArraySize));
    log(Priority::Unimportant, "particle array size: " + std::to_string(cellArraySize));
    log(Priority::Unimportant, "token array size: " + std::to_string(tokenArraySize));

        auto const memorySizeAfter = CudaMemoryManager::getInstance().getSizeOfAcquiredMemory();
    log(Priority::Important, std::to_string(memorySizeAfter / (1024 * 1024)) + " MB GPU memory acquired");
}
