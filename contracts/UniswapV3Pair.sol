// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.6.8;
pragma experimental ABIEncoderV2;

import '@uniswap/lib/contracts/libraries/TransferHelper.sol';
import '@uniswap/lib/contracts/libraries/FixedPoint.sol';
import '@uniswap/lib/contracts/libraries/Babylonian.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import './interfaces/IUniswapV3Pair.sol';
import { Aggregate, AggregateFunctions } from './libraries/AggregateFeeVote.sol';
import { Position, PositionFunctions } from './libraries/Position.sol';
import './libraries/SafeMath112.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/IUniswapV3Callee.sol';
import './libraries/FixedPointExtra.sol';
import './libraries/TickMath.sol';
import './libraries/PriceMath.sol';

contract UniswapV3Pair is IUniswapV3Pair {
    using SafeMath for uint;
    using SafeMath112 for uint112;
    using SafeMath112 for int112;
    using AggregateFunctions for Aggregate;
    using PositionFunctions for Position;
    using FixedPoint for FixedPoint.uq112x112;
    using FixedPointExtra for FixedPoint.uq112x112;
    using FixedPoint for FixedPoint.uq144x112;

    uint112 public constant override MINIMUM_LIQUIDITY = uint112(10**3);
    int16 public constant MAX_TICK = type(int16).max;
    int16 public constant MIN_TICK = type(int16).min;
    uint16 public constant MAX_FEEVOTE = 6000; // 60 bps
    uint16 public constant MIN_FEEVOTE = 0; // 0 bps

    address public immutable override factory;
    address public immutable override token0;
    address public immutable override token1;

    uint112 public totalFeeVote;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public override price0CumulativeLast;
    uint public override price1CumulativeLast;
    uint public override kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint112 private virtualSupply;  // current virtual supply;

    int16 public currentTick; // the current tick for the token0 price (rounded down)

    uint private unlocked = 1;
    
    // these only have relative meaning, not absolute—their value depends on when the tick is initialized
    struct TickInfo {
        uint32 secondsGrowthOutside;         // measures number of seconds spent while pool was on other side of this tick (from the current price)
        FixedPoint.uq112x112 kGrowthOutside; // measures growth due to fees while pool was on the other side of this tick (from the current price)
    }

    mapping (int16 => TickInfo) tickInfos;  // mapping from tick indexes to information about that tick
    mapping (int16 => int112) deltas;       // mapping from tick indexes to amount of token0 kicked in or out when tick is crossed going from left to right (token0 price going up)

    Aggregate aggregateFeeVote;
    mapping (int16 => Aggregate) deltaFeeVotes;       // mapping from tick indexes to amount of token0 kicked in or out when tick is crossed

    // TODO: is this really the best way to map (address, int16, int16) to position
    // keccak256(abi.encodePacked(address, int16, int16))
    mapping (bytes32 => Position) positions;

    modifier lock() {
        require(unlocked == 1, 'UniswapV3: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // returns sqrt(x*y)/shares
    function getInvariant() public view returns (FixedPoint.uq112x112 memory k) {
        uint112 rootXY = uint112(Babylonian.sqrt(uint256(reserve0) * uint256(reserve1)));
        return FixedPoint.encode(rootXY).div(virtualSupply);
    }

    function getGrowthAbove(int16 tickIndex, int16 _currentTick, FixedPoint.uq112x112 memory _k) public view returns (FixedPoint.uq112x112 memory) {
        FixedPoint.uq112x112 memory kGrowthOutside = tickInfos[tickIndex].kGrowthOutside;
        if (_currentTick >= tickIndex) {
            // this range is currently active
            return _k.uqdiv112(kGrowthOutside);
        } else {
            // this range is currently inactive
            return kGrowthOutside;
        }
    }

    function getGrowthBelow(int16 tickIndex, int16 _currentTick, FixedPoint.uq112x112 memory _k) public view returns (FixedPoint.uq112x112 memory) {
        FixedPoint.uq112x112 memory kGrowthOutside = tickInfos[tickIndex].kGrowthOutside;
        if (_currentTick < tickIndex) {
            // this range is currently active
            return _k.uqdiv112(kGrowthOutside);
        } else {
            // this range is currently inactive
            return kGrowthOutside;
        }
    }

    // gets the growth in K for within a particular range
    // this only has relative meaning, not absolute
    function getGrowthInside(int16 _lowerTick, int16 _upperTick) public view returns (FixedPoint.uq112x112 memory growth) {
        // TODO: simpler or more precise way to compute this?
        FixedPoint.uq112x112 memory _k = getInvariant();
        int16 _currentTick = currentTick;
        FixedPoint.uq112x112 memory growthAbove = getGrowthAbove(_upperTick, _currentTick, _k);
        FixedPoint.uq112x112 memory growthBelow = getGrowthBelow(_lowerTick, _currentTick, _k);
        return growthAbove.uqmul112(growthBelow).reciprocal().uqmul112(_k);
    }

    function getReserves() public override view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    constructor(address token0_, address token1_) public {
        factory = msg.sender;
        token0 = token0_;
        token1 = token1_;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint112 _oldReserve0, uint112 _oldReserve1, uint112 _newReserve0, uint112 _newReserve1) private {
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _oldReserve0 != 0 && _oldReserve1 != 0) {
            // + overflow is desired
            price0CumulativeLast += FixedPoint.encode(_oldReserve1).div(_oldReserve0).mul(timeElapsed).decode144();
            price1CumulativeLast += FixedPoint.encode(_oldReserve0).div(_oldReserve1).mul(timeElapsed).decode144();
        }
        reserve0 = _newReserve0;
        reserve1 = _newReserve1;
        blockTimestampLast = blockTimestamp;
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV3Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        uint112 _virtualSupply = virtualSupply;
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Babylonian.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Babylonian.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = uint(_virtualSupply).mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint112 liquidity = uint112(numerator / denominator);
                    if (liquidity > 0) {
                        positions[keccak256(abi.encodePacked(feeTo, int16(0), int16(0)))].liquidity += liquidity;
                        virtualSupply = _virtualSupply + liquidity;
                    }
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    function getBalancesAtPrice(int112 liquidity, FixedPoint.uq112x112 memory price) internal pure returns (int112 balance0, int112 balance1) {
        balance0 = price.reciprocal().sqrt().smul112(liquidity);
        balance1 = price.smul112(balance0);
    }

    function getBalancesAtTick(int112 liquidity, int16 tick) internal pure returns (int112 balance0, int112 balance1) {
        if (tick == MIN_TICK || tick == MAX_TICK) {
            // this is a lie—one of them should be near infinite—but I think an innocuous lie since that one is never checked
            return (0, 0);
        }
        FixedPoint.uq112x112 memory price = TickMath.getPrice(tick);
        return getBalancesAtPrice(liquidity, price);
    }

    function initialAdd(uint112 amount0, uint112 amount1, int16 startingTick, uint16 feeVote) external override lock returns (uint112 liquidity) {
        require(virtualSupply == 0, "UniswapV3: ALREADY_INITIALIZED");
        require(feeVote >= MIN_FEEVOTE && feeVote <= MAX_FEEVOTE, "UniswapV3: INVALID_FEE_VOTE");
        FixedPoint.uq112x112 memory price = FixedPoint.encode(amount1).div(amount0);
        require(price._x > TickMath.getPrice(startingTick)._x && price._x < TickMath.getPrice(startingTick + 1)._x);
        bool feeOn = _mintFee(0, 0);
        liquidity = uint112(Babylonian.sqrt(uint256(amount0).mul(uint256(amount1))).sub(MINIMUM_LIQUIDITY));
        positions[keccak256(abi.encodePacked(address(0), MIN_TICK, MAX_TICK))] = Position({
            liquidity: MINIMUM_LIQUIDITY,
            lastAdjustedLiquidity: MINIMUM_LIQUIDITY,
            feeVote: feeVote
        });
        positions[keccak256(abi.encodePacked(msg.sender, MIN_TICK, MAX_TICK))] = Position({
            liquidity: liquidity,
            lastAdjustedLiquidity: liquidity,
            feeVote: feeVote
        });
        uint112 totalLiquidity = liquidity + MINIMUM_LIQUIDITY;
        virtualSupply = totalLiquidity;
        aggregateFeeVote = Aggregate({
            numerator: int112(feeVote).mul(int112(totalLiquidity)),
            denominator: int112(totalLiquidity)
        });
        uint112 _reserve0 = amount0;
        uint112 _reserve1 = amount1;
        _update(0, 0, _reserve0, _reserve1);
        currentTick = startingTick;
        TransferHelper.safeTransferFrom(token0, msg.sender, address(this), amount0);
        TransferHelper.safeTransferFrom(token1, msg.sender, address(this), amount1);
        if (feeOn) kLast = uint(_reserve0).mul(_reserve1);
        emit SetPosition(address(0), int112(MINIMUM_LIQUIDITY), MIN_TICK, MAX_TICK, feeVote);
        emit SetPosition(msg.sender, int112(liquidity), MIN_TICK, MAX_TICK, feeVote);
    }

    // called when adding or removing liquidity that is within range
    function updateVirtualLiquidity(int112 liquidity, Aggregate memory deltaFeeVote) internal returns (int112 virtualAmount0, int112 virtualAmount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        (virtualAmount0, virtualAmount1) = getBalancesAtPrice(liquidity, FixedPoint.encode(reserve1).div(reserve0));
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint112 _virtualSupply = virtualSupply; // gas savings, must be defined here since virtualSupply can update in _mintFee
        // price doesn't change, so no need to update oracle
        virtualSupply = _virtualSupply.sadd(int112(int(virtualAmount0) * int(_virtualSupply) / int(reserve0)));
        _reserve0 = _reserve0.sadd(virtualAmount0);
        _reserve1 = _reserve1.sadd(virtualAmount1);
        (reserve0, reserve1) = (_reserve0, _reserve1);
        if (feeOn) kLast = uint(_reserve0).mul(_reserve1);
        aggregateFeeVote = aggregateFeeVote.add(deltaFeeVote);
    }

    function _getOrInitializeTick(int16 tickIndex, int16 _currentTick) internal {
        if (tickInfos[tickIndex].kGrowthOutside._x == 0) {
            // by convention, we assume that all growth before tick was initialized happened _below_ a tick
            if (tickIndex <= _currentTick) {
                tickInfos[tickIndex] = TickInfo({
                    secondsGrowthOutside: uint32(now % 2**32),
                    kGrowthOutside: getInvariant()
                });
            } else {
                tickInfos[tickIndex] = TickInfo({
                    secondsGrowthOutside: 0,
                    kGrowthOutside: FixedPoint.encode(1)
                });
            }
        }
    }

    // add or remove a specified amount of liquidity from a specified range, and/or change feeVote for that range
    function setPosition(int112 liquidity, int16 lowerTick, int16 upperTick, uint16 feeVote) external override lock {
        require(feeVote > MIN_FEEVOTE && feeVote < MAX_FEEVOTE, "UniswapV3: INVALID_FEE_VOTE");
        require(lowerTick < upperTick, "UniswapV3: BAD_TICKS");
        bytes32 positionKey = keccak256(abi.encodePacked(msg.sender, lowerTick, upperTick));
        require(virtualSupply > 0, 'UniswapV3: NOT_INITIALIZED');
        Position memory _position = positions[positionKey];
        int16 _currentTick = currentTick;
        // initialize tickInfos if they don't exist yet
        _getOrInitializeTick(lowerTick, _currentTick);
        _getOrInitializeTick(upperTick, _currentTick);
        // adjust liquidity values based on fees accumulated in the range
        FixedPoint.uq112x112 memory adjustmentFactor = getGrowthInside(lowerTick, upperTick);
        int112 adjustedExistingLiquidity = adjustmentFactor.smul112(int112(_position.liquidity));
        int112 adjustedNewLiquidity = adjustmentFactor.smul112(liquidity);
        uint112 totalAdjustedLiquidity = uint112(adjustedExistingLiquidity).sadd(adjustedNewLiquidity);
        // update position
        Position memory newPosition = Position({
            lastAdjustedLiquidity: totalAdjustedLiquidity,
            liquidity: _position.liquidity.sadd(liquidity),
            feeVote: feeVote
        });
        positions[positionKey] = newPosition;
        // before moving on, withdraw any collected fees
        // until fees are collected, they are like unlevered pool shares that do not earn fees outside the range
        FixedPoint.uq112x112 memory currentPrice = FixedPoint.encode(reserve1).div(reserve0);
        int112 feeLiquidity = adjustedExistingLiquidity - int112(_position.lastAdjustedLiquidity);
        // negative amount means the amount is sent out
        (int112 amount0, int112 amount1) = getBalancesAtPrice(-feeLiquidity, currentPrice);
        // update vote deltas. since adjusted liquidity and vote could change, remove all votes and add new ones
        Aggregate memory deltaFeeVote = newPosition.totalFeeVote().sub(_position.totalFeeVote());
        /* stack too deep
        deltaFeeVotes[lowerTick] = deltaFeeVotes[lowerTick].add(deltaFeeVote);
        deltaFeeVotes[upperTick] = deltaFeeVotes[upperTick].sub(deltaFeeVote);
        // calculate how much the newly added/removed shares are worth at lower ticks and upper ticks
        (int112 lowerToken0Balance, int112 lowerToken1Balance) = getBalancesAtTick(adjustedNewLiquidity, lowerTick);
        (int112 upperToken0Balance, int112 upperToken1Balance) = getBalancesAtTick(adjustedNewLiquidity, upperTick);
        // update token0 deltas
        deltas[lowerTick] = deltas[lowerTick].add(lowerToken0Balance);
        deltas[upperTick] = deltas[upperTick].sub(upperToken0Balance);
        if (currentTick < lowerTick) {
            amount1 = amount1.add(upperToken1Balance.sub(lowerToken1Balance));
        } else if (currentTick < upperTick) {
            (int112 virtualAmount0, int112 virtualAmount1) = updateVirtualLiquidity(adjustedNewLiquidity, deltaFeeVote);
            amount0 = amount0.add(virtualAmount0.sub(upperToken0Balance));
            amount1 = amount1.add(virtualAmount1.sub(lowerToken1Balance));
        } else {
            amount0 = amount0.add(lowerToken0Balance.sub(upperToken0Balance));
        }
        if (amount0 >= 0) {
            TransferHelper.safeTransferFrom(token0, msg.sender, address(this), uint112(amount0));
        } else {
            TransferHelper.safeTransfer(token0, msg.sender, uint112(-amount0));
        }
        if (amount1 >= 0) {
            TransferHelper.safeTransferFrom(token1, msg.sender, address(this), uint112(amount1));
        } else {
            TransferHelper.safeTransfer(token1, msg.sender, uint112(-amount1));
        }
        emit SetPosition(msg.sender, liquidity, lowerTick, upperTick, feeVote);*/
    }



    // TODO: implement swap1for0, or integrate it into this
    function swap0for1(uint amountIn, address to, bytes calldata data) external lock {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        (uint112 _oldReserve0, uint112 _oldReserve1) = (_reserve0, _reserve1);
        int16 _currentTick = currentTick;
        uint112 totalAmountOut = 0;
        uint112 amountInLeft = uint112(amountIn);
        uint112 amountOut = 0;
        Aggregate memory _aggregateFeeVote = aggregateFeeVote;
        uint112 _lpFee = _aggregateFeeVote.averageFee();
        /* stack too deep
        while (amountInLeft > 0) {
            FixedPoint.uq112x112 memory price = TickMath.getPrice(_currentTick);
            // compute how much would need to be traded to get to the next tick down
            uint112 maxAmount = PriceMath.getTradeToRatio(_reserve0, _reserve1, _lpFee, price);
            uint112 amountInStep = (amountInLeft > maxAmount) ? maxAmount : amountInLeft;
            // execute the sell of amountToTrade
            uint112 adjustedAmountToTrade = amountInStep * (1000000 - _lpFee) / 1000000;
            uint112 amountOutStep = (adjustedAmountToTrade * _reserve1) / (_reserve0 + adjustedAmountToTrade);
            amountOut = amountOut.add(amountOutStep);
            _reserve0 = _reserve0.add(amountInStep);
            _reserve1 = _reserve1.sub(amountOutStep);
            amountInLeft = amountInLeft.sub(amountInStep);
            if (amountInLeft > 0) { // shift past the tick
                TickInfo memory _oldTickInfo = tickInfos[_currentTick];
                if (_oldTickInfo.kGrowthOutside._x == 0) {
                    _currentTick -= 1;
                    continue;
                }
                // TODO (eventually): batch all updates, including from mintFee
                bool feeOn = _mintFee(_reserve0, _reserve1);
                FixedPoint.uq112x112 memory k = FixedPoint.encode(uint112(Babylonian.sqrt(uint(_reserve0) * uint(_reserve1)))).div(virtualSupply);
                FixedPoint.uq112x112 memory _oldKGrowthOutside = _oldTickInfo.kGrowthOutside._x != 0 ? _oldTickInfo.kGrowthOutside : FixedPoint.encode(uint112(1));
                // kick in/out liquidity
                int112 _delta = deltas[_currentTick] * -1; // * -1 because we're crossing the tick from right to left 
                _reserve0 = _reserve0.sadd(_delta);
                _reserve1 = _reserve1.sadd(price.smul112(_delta));
                int112 shareDelta = int112(int(virtualSupply) * int(_delta) / int(_reserve0));
                virtualSupply = virtualSupply.sadd(shareDelta);
                // kick in/out fee votes
                _aggregateFeeVote = _aggregateFeeVote.sub(deltaFeeVotes[_currentTick]); // sub because we're crossing the tick from right to left
                _lpFee = _aggregateFeeVote.averageFee();
                // update tick info
                tickInfos[_currentTick] = TickInfo({
                    // overflow is desired
                    secondsGrowthOutside: uint32(block.timestamp % 2**32) - _oldTickInfo.secondsGrowthOutside,
                    kGrowthOutside: k.uqdiv112(_oldKGrowthOutside)
                });
                _currentTick -= 1;
                if (feeOn) kLast = uint(_reserve0).mul(_reserve1);
            }
        }
        currentTick = _currentTick;
        // TODO: record new fees or something?
        emit Shift(_currentTick);
        TransferHelper.safeTransfer(token1, msg.sender, amountOut);
        if (data.length > 0) IUniswapV3Callee(to).uniswapV3Call(msg.sender, 0, totalAmountOut, data);
        TransferHelper.safeTransferFrom(token0, msg.sender, address(this), amountIn);
        _update(_oldReserve0, _oldReserve1, _reserve0, _reserve1);
        emit Swap(msg.sender, false, amountIn, amountOut, to);*/
    }
}