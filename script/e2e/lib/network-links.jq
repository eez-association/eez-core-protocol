# Reject malformed or inexact quantities instead of rounding RPC identities.
def require($ok; $why): if $ok then . else error($why) end;
def quantity:
    if type=="number" then .
    elif type=="string" and test("^0[xX][0-9a-fA-F]+$") then
        reduce (ascii_downcase|ltrimstr("0x")|explode[]) as $c
            (0; . * 16 + ("0123456789abcdef"|index([$c]|implode)))
    else error("invalid RPC quantity") end |
    require(.>=0 and .==floor and .<=9007199254740991; "quantity outside exact integer range");

# Canonical ordering must not depend on RPC hex padding or case.
def position: [(.blockNumber|quantity),(.transactionIndex|quantity)];
def calls($address; $topic):
    [.logs[]|select((.address|ascii_downcase)==$address and .topics[0]==$topic)] |
    sort_by(.logIndex|quantity);

# Normalize each reference while binding it to the expected Ethereum chain ID.
def hash: strings | select(test("^0x[0-9a-fA-F]{64}$")) | ascii_downcase;
def reference($chain; $id; $role):
    select((.chainId|quantity)==($id|quantity)) |
    {chain:$chain,chainId:$id,hash:(.hash|hash),role:$role};

# Require the source and the supported posting layout, preserving delivery multiplicity.
def status($source; $chain; $l1; $l2; $observation; $time):
    . as $s | .transactions as $t |
    [($t.l1|reference("L1";$l1;if $chain=="L1" then "source" else "l1-execution" end)),
     ($t.postBatch|reference("L1";$l1;"l1-post-batch"))] as $l1refs |
    select(($l1refs|length)==2 and ($t.l2|type)=="array") |
    [$t.l2[]|reference("L2";$l2;if $chain=="L1" then "l2-delivery"
        elif (.hash|hash)==$source then "source" else "l2-table-load" end)] as $l2refs |
    select(($l2refs|length)==($t.l2|length) and
        ($l2refs|map(.hash)|unique|length)==($l2refs|length)) |
    select(if $chain=="L1" then $l1refs[0].hash==$source
        else $l1refs[0].hash==$l1refs[1].hash and any($l2refs[]; .hash==$source) end) |
    {sourceChain:$chain,sourceHash:$source,direction:$s.direction,lifecycle:$s.lifecycle,
     ownership:$s.ownership,sender:$s.sender,nonce:$s.nonce,basis:$t.basis,attemptGeneration:$t.attemptGeneration,
     observation:$observation,observedAt:$time,references:($l1refs+$l2refs)};

# The receipt and signed transaction must agree on success, inclusion, chain and target.
def inclusion($e; $manager):
    . as $r | $e[.chain+":"+.hash] as $item | $item.receipt as $receipt | $item.transaction as $tx |
    require($receipt.transactionHash==$r.hash and $tx.hash==$r.hash and
        ($receipt.status|quantity)==1; "linked receipt failed") |
    require($receipt.blockHash==$tx.blockHash and
        all(["blockNumber","transactionIndex"][]; ($receipt[.]|quantity)==($tx[.]|quantity)); "inclusion mismatch") |
    require($tx.chainId==null or ($tx.chainId|quantity)==($r.chainId|quantity); "signed chain mismatch") |
    require((.role!="l2-table-load" and .role!="l2-delivery") or
        (($receipt.to|ascii_downcase)==$manager and ($tx.to|ascii_downcase)==$manager); "table targets another manager") |
    . + ($receipt|{blockHash,blockNumber,transactionIndex});

# Bind source identity and loader/delivery order independently of composer assertions.
def source_execution($e; $manager; $registry; $consumed; $incoming; $rollup):
    $e[.sourceChain+":"+.sourceHash] as $source |
    require(.sender==null or (.sender|ascii_downcase)==($source.transaction.from|ascii_downcase); "source sender mismatch") |
    require(.nonce==null or (.nonce|quantity)==($source.transaction.nonce|quantity); "source nonce mismatch") |
    .references |= map(inclusion($e; $manager)) |
    ([.references[]|select(.role=="l2-table-load" or .role=="l2-delivery")]|sort_by(position)) as $tables |
    require(if .sourceChain=="L2" then
        ($tables|length)==1 and $tables[0].blockHash==$source.receipt.blockHash and
        ($tables[0]|position)<($source.receipt|position)
    else
        ($source.receipt|calls($registry;$consumed)|map(select(.topics[2]==$rollup)|.topics[1])) ==
        [$tables[]|$e["L2:"+.hash].receipt|calls($manager;$incoming)|
            require(length==1; "delivery must emit one incoming call")|.[0].topics[1]]
    end; "links do not match this source execution") |
    require(.ownership.canonical==null or .ownership.canonical.hash==.references[0].blockHash; "ownership inclusion mismatch") |
    .checks=["reference-shape","chain-identity","successful-receipts","source-association"];

# A system table transaction cannot be attributed to multiple source transactions.
def evidence($manager; $registry; $consumed; $incoming; $rollup):
    .[1] as $e | .[0] | map(source_execution($e; $manager; $registry; $consumed; $incoming; $rollup)) |
    require(([.[].references[]|select(.role=="l2-table-load" or .role=="l2-delivery")|.hash]|
        group_by(.)|all(.[];length==1)); "L2 table attributed to multiple sources");

# Compare execution identity, not optional diagnostic timestamps added by the
# composer after commitment. Ownership, replacement and attempt changes still retry.
def execution_identity:
    {sourceHash,direction,basis,
     attemptGeneration:(if .attemptGeneration==null then null else .attemptGeneration|quantity end),
     ownership:(.ownership | {state,reason,replacementHash,rejection,
         canonical:(if .canonical==null then null else .canonical |
             {hash,number:(if .number==null then null else .number|quantity end)} end)}),
     references:([.references[]|{chain,hash}]|sort_by(.chain,.hash))};
