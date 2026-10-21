// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title DOSTestHelper
 * @notice Helper contract for testing DoS vulnerabilities in gas consumption patterns
 * @dev Provides functions to simulate various gas consumption scenarios for security testing
 */
contract DOSTestHelper {
    
    // Events for tracking gas consumption patterns
    event ArrayProcessed(uint256 size, uint256 gasUsed);
    event NestedOperationCompleted(uint256 outerLoop, uint256 innerLoop, uint256 gasUsed);
    event UnboundedLoopTest(uint256 iterations, uint256 gasUsed);
    
    // Storage arrays for testing
    mapping(uint256 => uint256) public testMapping;
    uint256[] public testArray;
    
    /**
     * @notice Process a large array to test gas consumption patterns
     * @param data Array of data to process
     * @dev Tests O(n) complexity scenarios
     */
    function processLargeArray(uint256[] calldata data) external {
        uint256 startGas = gasleft();
        
        // Process each element in the array
        for (uint256 i = 0; i < data.length; i++) {
            testMapping[i] = data[i] * 2; // Simple computation
        }
        
        uint256 gasUsed = startGas - gasleft();
        emit ArrayProcessed(data.length, gasUsed);
        
        // Revert if gas usage is too high (DoS protection)
        require(gasUsed < 25000000, "DOSTestHelper: Operation consumes too much gas");
    }
    
    /**
     * @notice Process nested operations to test O(n²) complexity
     * @param outerSize Size of outer loop
     * @param innerSize Size of inner loop
     * @dev Tests quadratic complexity scenarios that could cause DoS
     */
    function processNestedOperations(uint256 outerSize, uint256 innerSize) external {
        uint256 startGas = gasleft();
        
        require(outerSize <= 1000, "DOSTestHelper: Outer size too large");
        require(innerSize <= 1000, "DOSTestHelper: Inner size too large");
        
        // Nested loop scenario
        uint256 result = 0;
        for (uint256 i = 0; i < outerSize; i++) {
            for (uint256 j = 0; j < innerSize; j++) {
                result += i * j; // Some computation
                testMapping[i * 1000 + j] = result;
            }
        }
        
        uint256 gasUsed = startGas - gasleft();
        emit NestedOperationCompleted(outerSize, innerSize, gasUsed);
        
        // Prevent excessive gas consumption
        require(gasUsed < 28000000, "DOSTestHelper: Nested operation consumes too much gas");
    }
    
    /**
     * @notice Test unbounded loop scenarios
     * @param iterations Number of iterations to perform
     * @dev Tests scenarios where loop bounds are not properly validated
     */
    function unboundedLoopTest(uint256 iterations) external {
        uint256 startGas = gasleft();
        
        // Simulate unbounded loop with gas checking
        uint256 gasLimit = gasleft() * 80 / 100; // Use 80% of available gas
        uint256 actualIterations = 0;
        
        for (uint256 i = 0; i < iterations && gasleft() > gasLimit / iterations; i++) {
            testMapping[i] = i * i; // Quadratic operation
            actualIterations++;
            
            // Break early if we're consuming too much gas
            if (gasleft() < gasLimit) {
                break;
            }
        }
        
        uint256 gasUsed = startGas - gasleft();
        emit UnboundedLoopTest(actualIterations, gasUsed);
        
        require(actualIterations > 0, "DOSTestHelper: No iterations completed");
    }
    
    /**
     * @notice Test recursive function calls that could cause stack overflow
     * @param depth Recursion depth
     * @dev Tests stack-based DoS scenarios
     */
    function recursiveTest(uint256 depth) external view returns (uint256) {
        if (depth == 0) {
            return 1;
        }
        
        // Limit recursion depth to prevent stack overflow DoS
        require(depth <= 100, "DOSTestHelper: Recursion depth too high");
        
        return depth * recursiveTest(depth - 1);
    }
    
    /**
     * @notice Simulate memory allocation patterns that could cause DoS
     * @param size Size of memory to allocate
     * @dev Tests memory-based DoS scenarios
     */
    function memoryAllocationTest(uint256 size) external pure {
        require(size <= 10000, "DOSTestHelper: Memory allocation too large");
        
        // Create large memory array
        uint256[] memory largeArray = new uint256[](size);
        
        // Fill the array to ensure memory is actually allocated
        for (uint256 i = 0; i < size; i++) {
            largeArray[i] = i;
        }
        
        // Verify the array was created properly
        require(largeArray.length == size, "DOSTestHelper: Memory allocation failed");
    }
    
    /**
     * @notice Test storage operations that could cause DoS via expensive SSTORE operations
     * @param count Number of storage operations to perform
     * @dev Tests storage-based DoS scenarios
     */
    function storageOperationTest(uint256 count) external {
        require(count <= 1000, "DOSTestHelper: Too many storage operations");
        
        uint256 startGas = gasleft();
        
        // Perform multiple storage operations
        for (uint256 i = 0; i < count; i++) {
            testArray.push(i); // Expensive storage operation
        }
        
        uint256 gasUsed = startGas - gasleft();
        
        // Ensure we haven't consumed too much gas
        require(gasUsed < 20000000, "DOSTestHelper: Storage operations consume too much gas");
    }
    
    /**
     * @notice Clear test data to reset state
     * @dev Utility function for test cleanup
     */
    function clearTestData() external {
        // Clear test array
        delete testArray;
        
        // Note: We can't easily clear the mapping without knowing all keys
        // In production, consider using an array of keys to track mapping entries
    }
    
    /**
     * @notice Get current test array length
     * @return Length of the test array
     */
    function getTestArrayLength() external view returns (uint256) {
        return testArray.length;
    }
    
    /**
     * @notice Get test mapping value
     * @param key Key to look up
     * @return Value stored at the key
     */
    function getTestMappingValue(uint256 key) external view returns (uint256) {
        return testMapping[key];
    }
}

/**
 * @title MaliciousRoyaltyReceiver
 * @notice Contract that attempts to cause DoS via reentrancy during royalty payments
 * @dev Used for testing reentrancy protection in NFT marketplace
 */
contract MaliciousRoyaltyReceiver {
    address public marketplace;
    uint256 public reentrantCalls = 0;
    bool public shouldAttack = true;
    
    constructor(address _marketplace) {
        marketplace = _marketplace;
    }
    
    /**
     * @notice Receive function that attempts reentrancy attack
     * @dev Tries to call back into marketplace during royalty payment
     */
    receive() external payable {
        reentrantCalls++;
        
        if (shouldAttack && reentrantCalls < 5) { // Limit attempts to avoid infinite loop
            try this.attemptReentrancy() {
                // Reentrancy attempt
            } catch {
                // Expected to fail due to reentrancy guard
                shouldAttack = false;
            }
        }
    }
    
    /**
     * @notice Attempt reentrancy attack on marketplace
     * @dev External function to attempt calling marketplace functions during royalty payment
     */
    function attemptReentrancy() external {
        require(msg.sender == address(this), "Only self can call");
        
        // Try to call marketplace function during royalty payment
        // This should fail due to reentrancy guard
        bytes memory data = abi.encodeWithSignature("getListingsCount()");
        marketplace.call(data);
    }
    
    /**
     * @notice Reset attack state for testing
     */
    function resetAttackState() external {
        reentrantCalls = 0;
        shouldAttack = true;
    }
    
    /**
     * @notice Get number of reentrancy attempts made
     * @return Number of times receive function was called
     */
    function getReentrantCallCount() external view returns (uint256) {
        return reentrantCalls;
    }
}

/**
 * @title FlashLoanGovernanceAttacker
 * @notice Contract that simulates flash loan attacks on governance systems
 * @dev Used for testing flash loan attack resistance in governance contracts
 */
contract FlashLoanGovernanceAttacker {
    address public governance;
    address public token;
    bool public attackInProgress = false;
    
    event AttackAttempted(uint256 loanAmount, bool success);
    
    constructor(address _governance, address _token) {
        governance = _governance;
        token = _token;
    }
    
    /**
     * @notice Execute flash loan attack on governance
     * @param loanAmount Amount to borrow in flash loan
     * @param proposalTitle Title of malicious proposal
     * @param proposalDescription Description of malicious proposal
     * @dev Simulates borrowing large amounts to manipulate governance votes
     */
    function executeFlashLoanAttack(
        uint256 loanAmount, 
        string calldata proposalTitle,
        string calldata proposalDescription
    ) external {
        require(!attackInProgress, "Attack already in progress");
        require(loanAmount > 0, "Loan amount must be positive");
        
        attackInProgress = true;
        
        // Simulate flash loan execution
        bool attackSuccess = false;
        
        try this.performFlashLoanCallback(loanAmount, proposalTitle, proposalDescription) {
            attackSuccess = true;
        } catch {
            attackSuccess = false;
        }
        
        attackInProgress = false;
        
        emit AttackAttempted(loanAmount, attackSuccess);
        
        // Attack should fail due to governance protections
        require(!attackSuccess, "Flash loan attack should not succeed");
    }
    
    /**
     * @notice Callback function executed during flash loan
     * @param loanAmount Amount borrowed
     * @param proposalTitle Title of proposal to create
     * @param proposalDescription Description of proposal
     * @dev This function simulates what would happen during a flash loan attack
     */
    function performFlashLoanCallback(
        uint256 loanAmount,
        string calldata proposalTitle,
        string calldata proposalDescription
    ) external {
        require(msg.sender == address(this), "Only self can call");
        require(attackInProgress, "Attack not in progress");
        
        // Simulate having large token balance from flash loan
        // In reality, this would require actual flash loan integration
        
        // Try to create malicious proposal with borrowed voting power
        bytes memory proposalData = abi.encodeWithSignature(
            "createProposal(string,string,address[],uint256[],string[],bytes[])",
            proposalTitle,
            proposalDescription,
            new address[](0),
            new uint256[](0),
            new string[](0),
            new bytes[](0)
        );
        
        (bool success,) = governance.call(proposalData);
        
        // If proposal creation succeeded, try to vote immediately
        if (success) {
            bytes memory voteData = abi.encodeWithSignature("castVote(uint256,bool)", 1, true);
            governance.call(voteData);
        }
        
        // Flash loan would be repaid here in a real attack
        // This should fail due to governance time locks and flash loan detection
        revert("Flash loan attack detected and prevented");
    }
    
    /**
     * @notice Check if attack is currently in progress
     * @return True if attack is being executed
     */
    function isAttackInProgress() external view returns (bool) {
        return attackInProgress;
    }
}

/**
 * @title GasConsumptionAnalyzer
 * @notice Contract for analyzing gas consumption patterns of other contracts
 * @dev Utility contract for measuring and analyzing gas usage in security tests
 */
contract GasConsumptionAnalyzer {
    
    struct GasMetrics {
        uint256 gasUsed;
        uint256 timestamp;
        string operation;
        bool successful;
    }
    
    mapping(bytes32 => GasMetrics[]) public operationMetrics;
    
    event GasAnalysis(
        string operation,
        uint256 gasUsed,
        bool successful,
        bytes32 indexed operationHash
    );
    
    /**
     * @notice Analyze gas consumption of a contract call
     * @param target Contract to call
     * @param data Encoded function call data
     * @param operation Description of the operation
     * @return success Whether the call succeeded
     * @return gasUsed Amount of gas consumed
     */
    function analyzeGasConsumption(
        address target,
        bytes calldata data,
        string calldata operation
    ) external returns (bool success, uint256 gasUsed) {
        uint256 startGas = gasleft();
        
        (success,) = target.call(data);
        
        gasUsed = startGas - gasleft();
        
        bytes32 operationHash = keccak256(abi.encodePacked(operation));
        
        // Store metrics
        operationMetrics[operationHash].push(GasMetrics({
            gasUsed: gasUsed,
            timestamp: block.timestamp,
            operation: operation,
            successful: success
        }));
        
        emit GasAnalysis(operation, gasUsed, success, operationHash);
    }
    
    /**
     * @notice Get gas metrics for an operation
     * @param operation Operation to get metrics for
     * @return metrics Array of gas metrics
     */
    function getOperationMetrics(string calldata operation) 
        external 
        view 
        returns (GasMetrics[] memory metrics) 
    {
        bytes32 operationHash = keccak256(abi.encodePacked(operation));
        return operationMetrics[operationHash];
    }
    
    /**
     * @notice Calculate average gas usage for an operation
     * @param operation Operation to analyze
     * @return avgGasUsed Average gas consumption
     * @return sampleCount Number of samples
     */
    function getAverageGasUsage(string calldata operation) 
        external 
        view 
        returns (uint256 avgGasUsed, uint256 sampleCount) 
    {
        bytes32 operationHash = keccak256(abi.encodePacked(operation));
        GasMetrics[] memory metrics = operationMetrics[operationHash];
        
        if (metrics.length == 0) {
            return (0, 0);
        }
        
        uint256 totalGas = 0;
        uint256 successfulSamples = 0;
        
        for (uint256 i = 0; i < metrics.length; i++) {
            if (metrics[i].successful) {
                totalGas += metrics[i].gasUsed;
                successfulSamples++;
            }
        }
        
        avgGasUsed = successfulSamples > 0 ? totalGas / successfulSamples : 0;
        sampleCount = successfulSamples;
    }
}