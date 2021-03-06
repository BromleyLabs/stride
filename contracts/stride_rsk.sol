/** 
 * @title Stride RSK Contract 
 * @dev Contract on RSK for Stride transactions. The "forward" transaction,
 * for SBTC->EBTC is implemented using a cross-chain atomic swap where a
 * custodian is involved. The "reverse" tansaction, EBTC->SBTC, however, is 
 * automatic and is based on user providing proof of transaction of depositing
 * EBTC on Ethereum contract.  A one-time deposit of SBTC is done by the 
 * custodian and this is used as collateral against EBTC's issued to custodian.
 *
 * @author Bon Filey (bonfiley@gmail.com)
 * Copyright 2018 Bromley Labs Inc. 
 */ 

pragma solidity ^0.4.24;

import "safe_math.sol";
import "mortal.sol";
import "eth_proof.sol";
import "utils.sol";

contract StrideRSKContract is mortal {
    using SafeMath for uint;
    using StrideUtils for bytes;

    enum FwdTxnStates {UNINITIALIZED, DEPOSITED, ISSUED, CHALLENGED}

    struct ForwardTxn {  /* SBTC -> EBTC Transaction */
        uint txn_id; 
        address user_rsk; /* RSK address */
        bytes32 custodian_pwd_hash; /* Custodian password hash */
        uint creation_block; 
        uint sbtc_amount;
        FwdTxnStates state;
    } 

    struct EthTxnReceipt {
        uint status;
        address contract_addr;
        bytes32 event_hash;
        uint txn_block;
        address dest_addr;
        uint ebtc_amount;
    }

    mapping (uint => ForwardTxn) public m_fwd_txns;  
    mapping (bytes32 => bool) public m_sbtc_issued; /* receipt hash => true */

    address public m_custodian_rsk;   
    address public m_eth_contract_addr; /* Stride Ethereum contract */
    address public m_eth_proof_addr; /* Address of EthProof contract */
    bytes32 public m_eth_event_hash; /* Ethereum side event */ 
    uint public m_min_confirmations;
    uint public m_lock_interval; /* In blocks */
    uint public m_collateral = 0; 
    bool public m_collateral_deposited;

    event FwdUserDeposited(uint txn_id, uint sbtc_amount);
    event FwdSBTCIssued(uint txn_id, bytes pwd_str); 

    constructor(address custodian_addr, address eth_proof_addr, 
                address eth_contract_addr, uint min_confirmations, 
                uint lock_interval) public {
        m_custodian_rsk = custodian_addr;
        m_eth_proof_addr = eth_proof_addr;
        m_eth_contract_addr = eth_contract_addr;
        m_min_confirmations = min_confirmations;
        m_lock_interval = lock_interval; 
        m_eth_event_hash = keccak256("EBTCSurrendered(address,uint256,uint256,uint256)");
        m_collateral_deposited = false;
    }

    /**
     * @dev One time SBTC deposit by custodian. 
     */
    function deposit_collateral() public payable {
        require(msg.sender == m_custodian_rsk);
        require(!m_collateral_deposited); /* One time */

        m_collateral = msg.value;
        m_collateral_deposited = true;
    }  

    /**
     * @dev we don't want any SBTCs into this contract transfered via any
     * transaction other than the deposit_collateral() method 
     */
     function () public payable { 
        revert();
    }

    /** 
     * @dev Initate a cross atomic swap transfer by first depositing SBTC to 
     * this contract. Called by user. 
     */

    function fwd_deposit(uint txn_id, bytes32 custodian_pwd_hash) public 
                         payable {
        require(txn_id > 0);
        require(m_fwd_txns[txn_id].txn_id != txn_id, 
                "Transaction already exists");
        require(msg.value > 0, "SBTC cannot be 0"); 

        m_fwd_txns[txn_id] = ForwardTxn(txn_id, msg.sender, custodian_pwd_hash,
                                        block.number, msg.value, 
                                        FwdTxnStates.DEPOSITED);
        emit FwdUserDeposited(txn_id, msg.value);
    }

    /** 
     * @dev Send password string to user and receive SBTC. Called by custodian.
     */
    function fwd_issue(uint txn_id, bytes pwd_str) public { 
        ForwardTxn storage txn = m_fwd_txns[txn_id]; 
        require(msg.sender == m_custodian_rsk, "Only custodian can call this"); 
        require(txn.state == FwdTxnStates.DEPOSITED, 
                "Transaction not in DEPOSITED state");
        require(block.number <= (txn.creation_block + m_lock_interval));
        require(txn.custodian_pwd_hash == keccak256(pwd_str), 
                "Hash does not match");
  
        txn.state = FwdTxnStates.ISSUED;

        m_custodian_rsk.transfer(txn.sbtc_amount);

        emit FwdSBTCIssued(txn_id, pwd_str);
    }

    /** 
     * @dev Called by user. Refund in case no action by custodian. 
     */ 
    function fwd_no_custodian_action_challenge(uint txn_id) public {
        ForwardTxn storage txn = m_fwd_txns[txn_id]; 
        require(msg.sender == txn.user_rsk, "Only user can call this"); 
        require(txn.state == FwdTxnStates.DEPOSITED, "Transaction not in DEPOSITED state"); 
        require(block.number > (txn.creation_block + m_lock_interval));

        txn.state = FwdTxnStates.CHALLENGED;

        txn.user_rsk.transfer(txn.sbtc_amount);
    }

    /**
     * @dev Decode Ethereum transaction receipt and read fields of interest.
     * two event logs are expected - we are interested in the second log which 
     * is emitted  by rev_redeem() function on Ethereum contract. 
     * TODO: for status == 0 RLP.toUint() may fail as length of byte array is 0.
     */ 
    function parse_eth_txn_receipt(bytes rlp_txn_receipt) internal 
                                   returns (EthTxnReceipt) {
        EthTxnReceipt memory receipt = EthTxnReceipt(0,0,0,0,0,0);

        RLP.RLPItem memory item = RLP.toRLPItem(rlp_txn_receipt);
        RLP.RLPItem[] memory fields = RLP.toList(item);
        receipt.status = RLP.toUint(fields[0]);  /* See TODO note above */
     
        RLP.RLPItem[] memory logs = RLP.toList(fields[3]); 
        RLP.RLPItem[] memory log_fields = RLP.toList(logs[1]); /* Second log */
        receipt.contract_addr = RLP.toAddress(log_fields[0]);
   
        RLP.RLPItem[] memory topics = RLP.toList(log_fields[1]);
        receipt.event_hash = RLP.toBytes32(topics[0]);

        bytes memory event_data = RLP.toData(log_fields[2]);
        uint index = 0 + 12; /* Start of address in 32 bytes field */
        /* The data for some reason is all 32 bytes even for address */
        receipt.dest_addr = address(StrideUtils.get_bytes20(event_data, index)); 
        index += 20;
        receipt.ebtc_amount = uint(StrideUtils.get_bytes32(event_data, index)); 
        index += 32; 
        receipt.txn_block = uint(StrideUtils.get_bytes32(event_data, index));

        return receipt;
    }   


    /** 
     *  @dev Called by the user, this function redeems SBTC to the destination 
     *  address specified on Ethereum side.  The user provides proof of 
     *  Ethereum transaction receipt which is verified in this function. Reads
     *  logs in transaction receipt containing user RSK destination address and 
     *  SBTC amount (refer to Ethereum contract). 
     *  @param rlp_txn_receipt bytes The full transaction receipt structure 
     *  @param block_hash bytes32 Hash of the block in which Ethereum 
     *  transaction exists
     *  @param path bytes path of the Merkle proof to reach root node
     *  @param rlp_parent_nodes bytes Merkle proof in the form of trie
     */
    function rev_redeem(bytes rlp_txn_receipt, bytes32 block_hash, bytes path, bytes rlp_parent_nodes) public {

        require(m_sbtc_issued[keccak256(rlp_txn_receipt)] != true, 
                "SBTC already issued for this transaction");

        EthProof eth_proof = EthProof(m_eth_proof_addr); 
        require(eth_proof.check_receipt_proof(rlp_txn_receipt,
                block_hash, path, rlp_parent_nodes), "Incorrect proof");         
        
        EthTxnReceipt memory receipt = parse_eth_txn_receipt(rlp_txn_receipt);
        require(receipt.status == 1); /* Successful txn */
        uint curr_block =  eth_proof.m_highest_block();
        require((curr_block - receipt.txn_block) > m_min_confirmations);
        require(receipt.event_hash == m_eth_event_hash); 
        require(receipt.contract_addr == m_eth_contract_addr);

        m_sbtc_issued[keccak256(rlp_txn_receipt)] = true; 
        m_collateral = m_collateral.sub(receipt.ebtc_amount); /* SBTC==EBTC */
        receipt.dest_addr.transfer(receipt.ebtc_amount); 
    
    } 
}
