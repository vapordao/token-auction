import 'erc20/erc20.sol';

import 'assertive.sol';

// This contract contains a number of Auctions, each of which is
// *splittable*.  The splittable unit of an Auction is an Auctionlet,
// which has all of the Auctions properties but allows for bidding on a
// subset of the full Auction lot.
contract SplittableAuctionManager is Assertive {
    struct Auction {
        address beneficiary;
        ERC20 selling;
        ERC20 buying;
        uint min_bid;
        uint min_increase;
        uint sell_amount;
        uint collected;
        uint COLLECT_MAX;
        uint claimed;
        uint expiration;
        bool reversed;
        uint excess_claimable;
    }
    struct Auctionlet {
        uint     auction_id;
        address  last_bidder;
        uint     last_bid;
        uint     quantity;
        bool     claimed;
    }
    bool TRANSITION;
    uint constant INFINITY = 2 ** 256 - 1;

    mapping(uint => Auction) _auctions;
    uint _last_auction_id;

    mapping(uint => Auctionlet) _auctionlets;
    uint _last_auctionlet_id;

    // Create a new auction, with specific parameters.
    // Bidding is done through the auctions associated auctionlets,
    // of which there is one initially.
    function newAuction( address beneficiary
                        , ERC20 selling
                        , ERC20 buying
                        , uint sell_amount
                        , uint min_bid
                        , uint min_increase
                        , uint duration
                        )
        returns (uint)
    {
        return newTwoWayAuction(beneficiary, selling, buying, sell_amount,
                                min_bid, min_increase, duration, INFINITY);
    }
    function newTwoWayAuction( address beneficiary
                             , ERC20 selling
                             , ERC20 buying
                             , uint sell_amount
                             , uint min_bid
                             , uint min_increase
                             , uint duration
                             , uint COLLECT_MAX
                             )
        returns (uint)
    {
        Auction memory a;
        a.beneficiary = beneficiary;
        a.selling = selling;
        a.buying = buying;
        a.sell_amount = sell_amount;
        a.min_bid = min_bid;
        a.min_increase = min_increase;
        a.expiration = getTime() + duration;
        a.COLLECT_MAX = COLLECT_MAX;

        var received_lot = selling.transferFrom(beneficiary, this, sell_amount);
        assert(received_lot);

        _auctions[++_last_auction_id] = a;

        // create the base auctionlet
        newAuctionlet({auction_id: _last_auction_id,
                       quantity:    sell_amount});

        return _last_auction_id;
    }
    function newAuctionlet(uint auction_id, uint quantity)
        internal returns (uint)
    {
        Auctionlet memory auctionlet;
        auctionlet.auction_id = auction_id;
        auctionlet.quantity = quantity;

        _auctionlets[++_last_auctionlet_id] = auctionlet;

        return _last_auctionlet_id;
    }
    // bid on a specifc auctionlet
    function bid(uint auctionlet_id, uint bid_how_much) {
        var a = _auctionlets[auctionlet_id];
        var A = _auctions[a.auction_id];

        if (!A.reversed && (bid_how_much >= A.COLLECT_MAX)) {  // transition
            A.reversed = true;
            bid_how_much = a.quantity;
            A.collected = A.COLLECT_MAX;
            a.last_bid = a.quantity;
            TRANSITION = true;
        }
        _assertBiddable(auctionlet_id, bid_how_much);
        _doBid(auctionlet_id, msg.sender, bid_how_much);

        TRANSITION = false;
    }
    // bid on a specific quantity of an auctionlet
    function bid(uint auctionlet_id, uint bid_how_much, uint quantity)
        returns (uint, uint)
    {
        _assertSplittable(auctionlet_id, bid_how_much, quantity);
        return _doSplit(auctionlet_id, bid_how_much, quantity);
    }
    // Parties to an auction can claim their take. The auction creator
    // (the beneficiary) can claim across an entire auction. Individual
    // auctionlet high bidders must claim per auctionlet.
    function claim(uint id) {
        if (msg.sender == _auctions[id].beneficiary) {
            _doClaimSeller(id);
        } else {
            _doClaimBidder(id, msg.sender);
        }
    }
    // Check whether an auctionlet is eligible for bidding on
    function _assertBiddable(uint auctionlet_id, uint bid_how_much) internal {
        var a = _auctionlets[auctionlet_id];
        var A = _auctions[a.auction_id];

        assert(a.auction_id > 0);  // test for deleted auctionlet

        if (A.reversed) {
            //@log bid how much: `uint bid_how_much`
            //@log sell amount:  `uint A.sell_amount`
            //@log last bid:     `uint a.last_bid`
            assert(bid_how_much <= a.last_bid);
        } else {
            if (a.last_bidder == 0) {  // check for base auctionlet
                assert(bid_how_much >= A.min_bid);
            } else {
                assert(bid_how_much >= (a.last_bid + A.min_increase));
            }
        }

        var expired = A.expiration <= getTime();
        assert(!expired);
    }
    function _assertReverseBiddable(uint auctionlet_id, uint bid_how_much) internal {
        var a = _auctionlets[auctionlet_id];
        var A = _auctions[a.auction_id];

        assert(a.auction_id > 0);  // test for deleted auctionlet

        if (A.reversed) {
            //@log bid how much: `uint bid_how_much`
            //@log sell amount:  `uint A.sell_amount`
            //@log last bid:     `uint a.last_bid`
            if (a.last_bidder == 0) {  // check for base auctionlet
                assert(bid_how_much <= A.sell_amount);
            } else {
                assert(bid_how_much <= a.last_bid);
            }
        } else {
            if (a.last_bidder == 0) {  // check for base auctionlet
                assert(bid_how_much >= A.min_bid);
            } else {
                assert(bid_how_much >= (a.last_bid + A.min_increase));
            }
        }

        var expired = A.expiration <= getTime();
        assert(!expired);
    }
    // Check whether an auctionlet is eligible for splitting
    function _assertSplittable(uint auctionlet_id, uint bid_how_much, uint quantity)
        internal
    {
        var a = _auctionlets[auctionlet_id];

        // check that the split actually splits the auctionlet
        // with lower quantity
        assert(quantity < a.quantity);

        // check that there is a relative increase in value
        // ('valuation' is the bid scaled up to the full lot)
        // n.b avoid dividing by a.last_bid as it could be zero
        var valuation = (bid_how_much * a.quantity) / quantity;

        _assertBiddable(auctionlet_id, valuation);
    }
    function _doBid(uint auctionlet_id, address bidder, uint bid_how_much)
        internal
    {
        var a = _auctionlets[auctionlet_id];
        var A = _auctions[a.auction_id];

        bool received_bid;
        bool returned_bid;
        if (A.reversed && TRANSITION) {
        //@log balance:   `uint A.buying.balanceOf(this)`
            received_bid = A.buying.transferFrom(bidder, this, A.COLLECT_MAX);
            returned_bid = true;
        //@log balance:   `uint A.buying.balanceOf(this)`
        } else if (A.reversed) {
        //@log balance:   `uint A.buying.balanceOf(this)`
            received_bid = A.buying.transferFrom(bidder, this, A.COLLECT_MAX);
        //@log balance:   `uint A.buying.balanceOf(this)`
            returned_bid = A.buying.transfer(a.last_bidder, A.COLLECT_MAX);
        //@log balance:   `uint A.buying.balanceOf(this)`
            A.excess_claimable = A.sell_amount - bid_how_much;
        } else {
            received_bid = A.buying.transferFrom(bidder, this, bid_how_much);
            returned_bid = A.buying.transfer(a.last_bidder, a.last_bid);
            A.collected += bid_how_much;
            A.collected -= a.last_bid;
        }
        assert(received_bid);
        assert(returned_bid);

        a.last_bidder = bidder;
        a.last_bid = bid_how_much;
    }
    function _doSplit(uint auctionlet_id, uint bid_how_much, uint quantity)
        internal
        returns (uint, uint)
    {
        var a = _auctionlets[auctionlet_id];
        var A = _auctions[a.auction_id];

        var new_quantity = a.quantity - quantity;
        //@log previous quantity: `uint a.quantity`
        //@log modified quantity: `uint new_quantity`
        //@log split quantity:    `uint quantity`

        // n.b. associativity important because of truncating division
        var new_bid = (a.last_bid * new_quantity) / a.quantity;
        //@log previous bid: `uint a.last_bid`
        //@log modified bid: `uint new_bid`
        //@log split bid:    `uint bid_how_much`

        var returned_bid = A.buying.transfer(a.last_bidder, a.last_bid);
        assert(returned_bid);
        A.collected -= a.last_bid;

        // create two new auctionlets and bid on them
        var new_id = newAuctionlet(a.auction_id, new_quantity);
        var split_id = newAuctionlet(a.auction_id, quantity);

        _doBid(new_id, a.last_bidder, new_bid);
        _doBid(split_id, msg.sender, bid_how_much);

        delete _auctionlets[auctionlet_id];

        return (new_id, split_id);
    }
    // claim the existing bids from all auctionlets connected to a
    // specific auction
    function _doClaimSeller(uint auction_id) internal {
        var A = _auctions[auction_id];

        //@log collected: `uint A.collected`
        //@log claimed:   `uint A.claimed`
        //@log balance:   `uint A.buying.balanceOf(this)`
        var settled = A.buying.transfer(A.beneficiary, A.collected - A.claimed);
        assert(settled);

        // transfer excess sell token
        if (A.reversed) {
            var settled_excess = A.selling.transfer(A.beneficiary,
                                                    A.excess_claimable);
            assert(settled_excess);
            A.excess_claimable = 0;
        }

        A.claimed = A.collected;
    }
    // claim the proceedings from an auction for the highest bidder
    function _doClaimBidder(uint auctionlet_id, address claimer) internal {
        var a = _auctionlets[auctionlet_id];
        var A = _auctions[a.auction_id];

        assert(claimer == a.last_bidder);

        var expired = A.expiration <= getTime();
        assert(expired);

        assert(!a.claimed);

        // TODO: can we just decrease a.quantity with each bid?
        bool settled;
        if (A.reversed) {
            settled = A.selling.transfer(a.last_bidder, a.last_bid);
        } else {
            settled = A.selling.transfer(a.last_bidder, a.quantity);
        }
        assert(settled);

        a.claimed = true;
    }
    function getAuction(uint id) constant
        returns (address, ERC20, ERC20, uint, uint, uint, uint)
    {
        Auction a = _auctions[id];
        return (a.beneficiary, a.selling, a.buying,
                a.sell_amount, a.min_bid, a.min_increase, a.expiration);
    }
    function getAuctionlet(uint id) constant
        returns (uint, address, uint, uint)
    {
        Auctionlet a = _auctionlets[id];
        return (a.auction_id, a.last_bidder, a.last_bid, a.quantity);
    }
    function getTime() public constant returns (uint) {
        return block.timestamp;
    }
}
