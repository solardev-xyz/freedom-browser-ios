// The iPhone engine's domain service against a LOCAL Anvil fork of Ethereum
// mainnet: desktop's scripts/qualify-domains-fork.js (PR #1134), driving the
// iOS host interface (AgentDomains.swift's `domains` service) instead of
// desktop's wallet. A disposable impersonated account pays with fork-seeded
// USDC/DAI and ETH; nothing leaves this machine's Anvil.
//
//   anvil --fork-url <read-only Ethereum RPC> --host 127.0.0.1 --port 18549 --chain-id 1
//   node AgentEngine/test/domains-fork.mjs

import assert from 'node:assert/strict';
import { AbiCoder, Contract, Interface, JsonRpcProvider, dnsEncode, getAddress, keccak256, toQuantity } from 'ethers';
import { DomainChain } from '../src/domains/chain.js';
import { ABI, ZeroAddress, ZeroHash, commitmentFor, parseName, swarmContenthash } from '../src/domains/contracts.js';
import { LEGACY_WRAPPER_GRACE } from '../src/domains/ens-v2.js';
import { chainRequest } from '../src/domains/index.js';
import { DomainService } from '../src/domains/service.js';
import { DomainOperationStore } from '../src/domains/store.js';
import { DomainTransactions } from '../src/domains/transactions.js';

const url = new URL(process.env.FREEDOM_DOMAIN_FORK_URL || 'http://127.0.0.1:18549');
assert.equal(url.protocol, 'http:');
assert.equal(url.hostname, '127.0.0.1');
const provider = new JsonRpcProvider(url.href, 1, { staticNetwork: true });
const hex = bytes => Array.from(crypto.getRandomValues(new Uint8Array(bytes)), byte => byte.toString(16).padStart(2, '0')).join('');

try {
  assert.match(await provider.send('web3_clientVersion', []), /anvil/i);
  const address = getAddress(`0x${hex(20)}`);
  await provider.send('anvil_impersonateAccount', [address]);
  await provider.send('anvil_setBalance', [address, toQuantity(10n ** 23n)]);

  // The app side, as AgentDomains.swift implements it: journal and Keychain
  // in memory, gas +20%, approvals counted (always approved here), sends from
  // the impersonated account.
  const disk = { journal: null, secrets: new Map() };
  const quotes = new Map();
  let approvals = 0;
  let sent = 0;
  const titles = [];
  const host = async (method, params) => {
    switch (method) {
      case 'rpc': {
        // As AgentDomains.swift answers: { result }, or the node's { error } with its revert data.
        const response = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: params.method, params: params.params }) });
        const body = await response.json();
        return body.error ? { error: { code: body.error.code, message: body.error.message, data: body.error.data ?? null } } : { result: body.result };
      }
      case 'account': return { index: 0, address, name: 'Fork fixture' };
      case 'ownWallet': return params.address?.toLowerCase() === address.toLowerCase() ? { status: 'own', index: 0, name: 'Fork fixture' } : { status: 'other' };
      case 'balance': return { balanceWei: BigInt(await provider.send('eth_getBalance', [address, 'latest'])).toString() };
      case 'loadOperations': return disk.journal ? JSON.parse(disk.journal) : { operations: [] };
      case 'saveOperations': disk.journal = params.body; return true;
      case 'saveSecret': disk.secrets.set(params.handle, params.secret); return true;
      case 'readSecret': return { secret: disk.secrets.get(params.handle) ?? null };
      case 'deleteSecret': disk.secrets.delete(params.handle); return true;
      case 'quote': {
        assert.equal(params.from, address);
        const gas = BigInt(await provider.send('eth_estimateGas', [{ from: address, to: params.to, data: params.data, value: toQuantity(BigInt(params.value)) }])) * 120n / 100n;
        const gasPrice = BigInt(await provider.send('eth_gasPrice', []));
        const quoteId = hex(8);
        quotes.set(quoteId, { ...params, gas, gasPrice });
        return { quoteId, maxFeeWei: (gas * gasPrice).toString() };
      }
      case 'approve': {
        assert.ok(quotes.has(params.quoteId));
        assert.equal(params.presentation?.format, 'freedom-domain-approval/1');
        approvals++;
        titles.push(params.label);
        return { status: 'approved' };
      }
      case 'send': {
        const quote = quotes.get(params.quoteId);
        sent++;
        const hash = await provider.send('eth_sendTransaction', [{ from: address, to: quote.to, data: quote.data,
          value: toQuantity(BigInt(quote.value)), gas: toQuantity(quote.gas), gasPrice: toQuantity(quote.gasPrice) }]);
        return { hash };
      }
      case 'finish': quotes.delete(params.quoteId); return true;
      case 'verifyResolution': return { verified: false };
      default: throw new Error(`unexpected host call ${method}`);
    }
  };

  const chain = new DomainChain({ request: chainRequest(host) });
  // Seed only the disposable account's ERC20 balance in Anvil storage.
  const seedToken = async (role, amount) => {
    for (let index = 0; index < 40; index++) {
      const slot = keccak256(AbiCoder.defaultAbiCoder().encode(['address', 'uint256'], [address, index]));
      const before = await provider.send('eth_getStorageAt', [chain.addresses[role], slot, 'latest']);
      await provider.send('anvil_setStorageAt', [chain.addresses[role], slot, `0x${amount.toString(16).padStart(64, '0')}`]);
      const [balance] = await chain.call(role, 'balanceOf', [address], await chain.snapshot());
      if (balance === amount) return;
      await provider.send('anvil_setStorageAt', [chain.addresses[role], slot, before]);
    }
    throw new Error(`Could not seed the local ${role} fixture balance`);
  };
  await seedToken('usdc', 1000000000n);
  await seedToken('dai', 1000n * 10n ** 18n);

  const publicationId = `swarm_pub_${'ab'.repeat(16)}`;
  const reference = '12'.repeat(32);
  const open = async () => new DomainService({
    store: await DomainOperationStore.open(host), chain, wallet: new DomainTransactions(host), executeWaitMs: 30000, pollMs: 100,
    getPublication: async () => ({ publicationId, reference, state: 'completed', verified: true, public: true, target: 'public', indexDocument: 'index.html' }),
    verifyResolution: async (name, ref) => (await host('verifyResolution', { name, reference: ref }))?.verified === true,
  });
  let service = await open();
  const context = { conversationId: 'fork-fixture' };
  const finish = async plan => {
    let result = plan;
    for (let step = 0; step < 8 && result.state !== 'completed'; step++) {
      if (result.state === 'waiting_commitment') {
        await provider.send('evm_increaseTime', [61]); await provider.send('evm_mine', []);
        result = await service.status({ operationId: result.operationId });
      }
      assert.equal(result.state, 'ready', JSON.stringify(result));
      result = await service.execute(result.operationId, context);
    }
    assert.equal(result.state, 'completed', JSON.stringify(result));
    return result;
  };

  const label = `freedom-ios-fixture-${hex(6)}`;
  for (const namespace of ['eth', 'wei', 'gwei']) {
    const name = `${label}.${namespace}`;
    const before = sent;
    const inspected = await service.inspect({ name });
    assert.equal(inspected.available, true);
    if (namespace === 'eth') {
      assert.equal(inspected.quote.currency, 'USDC');
      assert.equal(inspected.ensVersion, 2); // Unregistered labels are ENSv2's.
    }
    const prepared = await service.prepare({ name, intent: 'register' }, context);
    assert.equal(prepared.state, 'ready', JSON.stringify(prepared));
    let receipt = await service.execute(prepared.operationId, context);
    assert.ok(['waiting_commitment', 'ready'].includes(receipt.state), JSON.stringify(receipt));
    // The secret stays in the Keychain stand-in, never in the journal or the tool result.
    const handle = JSON.parse(disk.journal).operations.find(item => item.id === prepared.operationId).encryptedSecret;
    const secret = disk.secrets.get(handle);
    assert.match(secret, /^0x[a-f0-9]{64}$/);
    assert.ok(!JSON.stringify(receipt).includes(secret.slice(2)));
    assert.ok(!disk.journal.includes(secret.slice(2)));
    // Restart while waiting: recover from the app's journal and Keychain only.
    service.close();
    service = await open();
    await provider.send('evm_increaseTime', [61]); await provider.send('evm_mine', []);
    receipt = await service.status({ operationId: prepared.operationId });
    assert.equal(receipt.state, 'ready', JSON.stringify(receipt));
    receipt = await finish(receipt);
    assert.ok(sent - before >= 2);
    await service.store.flush();
    assert.equal(JSON.parse(disk.journal).operations.find(item => item.id === prepared.operationId).encryptedSecret, undefined);
    assert.equal(disk.secrets.has(handle), false, 'the finished registration secret is deleted');
    const state = await service.inspect({ name });
    assert.equal(state.owner, address);
    if (namespace === 'eth') assert.equal(state.ensVersion, 2);
    for (const change of [
      { intent: 'renew' },
      { intent: 'set_text', key: 'description', value: 'iPhone fork fixture' },
      { intent: 'set_address', address },
      { intent: 'set_website', publicationId },
      { intent: 'clear_website' },
    ]) {
      const result = await finish(await service.prepare({ name, ...change }, context));
      assert.equal(result.state, 'completed', `${namespace}: ${change.intent}: ${JSON.stringify(result)}`);
      if (change.intent === 'set_website') {
        const updated = await service.inspect({ name, textKeys: ['description'] });
        assert.equal(updated.records.contenthash, swarmContenthash(reference));
        assert.equal(updated.records.text.description, 'iPhone fork fixture');
        assert.equal(updated.records.address, address);
        if (namespace === 'eth') {
          // The Universal Resolver Freedom's iOS ENS resolver also uses reaches the new records.
          const universal = new Contract('0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe', ['function resolve(bytes,bytes) view returns(bytes,address)'], provider);
          const [resolved] = await universal.resolve(dnsEncode(name, 255), ABI.resolver.encodeFunctionData('contenthash', [parseName(name).node]));
          assert.equal(ABI.resolver.decodeFunctionResult('contenthash', resolved)[0], swarmContenthash(reference));
        }
      }
    }
    const sentBeforeReplay = sent;
    await service.execute(prepared.operationId, context);
    assert.equal(sent, sentBeforeReplay, 'a completed operation is not sent again');
    if (namespace === 'eth') {
      // A v2 name pointed at a resolver that isn't ENS's: the factory's
      // VerificationFailed revert must reach the engine as data, so inspection
      // reports an unsupported resolver instead of failing.
      const owned = await service.inspect({ name });
      const custom = chain.addresses.usdc;
      const hash = await provider.send('eth_sendTransaction', [{ from: address, to: chain.addresses.ensRegistry,
        data: new Interface(['function setResolver(uint256,address)']).encodeFunctionData('setResolver', [owned.registryTokenId, custom]), gas: '0x80000' }]);
      assert.equal((await provider.waitForTransaction(hash)).status, 1);
      const customState = await service.inspect({ name });
      assert.equal(customState.resolver.toLowerCase(), custom.toLowerCase());
      assert.equal(customState.supportedResolver, false);
      assert.ok(!customState.supportedActions.includes('set_text'));
      assert.ok(customState.supportedActions.includes('renew'));
      console.log(JSON.stringify({ customResolver: 'reported unsupported, inspection works' }));
    }
    console.log(JSON.stringify({ namespace, registration: 'confirmed', restart: 'recovered', renewal: 'verified', records: 'verified', replay: 'no second send', transactions: sent - before }));
  }

  // The engine's ENSv2 commitment equals the deployed registrar's.
  const vector = { ...parseName(`${label}-vector.eth`), protocol: 'ensv2', account: { address }, duration: 31536000, ensResolver: ZeroAddress };
  const dummySecret = `0x${'42'.repeat(32)}`;
  assert.equal((await chain.call('ensRegistrar', 'makeCommitment', [vector.label, address, dummySecret, ZeroAddress, ZeroAddress, 31536000, ZeroHash], await chain.snapshot()))[0],
    commitmentFor(vector, dummySecret));

  const daiName = `${label}-dai.eth`;
  await finish(await service.prepare({ name: daiName, intent: 'register', paymentToken: 'DAI' }, context));
  await finish(await service.prepare({ name: daiName, intent: 'renew', paymentToken: 'DAI' }, context));
  assert.equal((await service.inspect({ name: daiName })).owner, address);
  console.log(JSON.stringify({ dai: 'registration and renewal verified', commitmentVector: 'matches deployed registrar' }));

  // Legacy v1 names renew through ENS's legacy renewer. wrapped.eth is wrapped
  // inside this fork only (desktop's fixture); real owners are untouched.
  const legacy = await service.inspect({ name: 'wrapped.eth' });
  assert.equal(legacy.ensVersion, 1);
  if (!legacy.wrapped) {
    await provider.send('anvil_impersonateAccount', [legacy.owner]);
    await provider.send('anvil_setBalance', [legacy.owner, toQuantity(10n ** 21n)]);
    for (const [to, signature, method, args] of [
      [chain.addresses.base, 'function approve(address,uint256)', 'approve', [chain.addresses.wrapper, legacy.tokenId]],
      [chain.addresses.wrapper, 'function wrapETH2LD(string,address,uint16,address)', 'wrapETH2LD', [legacy.label, legacy.owner, 0, chain.addresses.resolver]],
    ]) {
      const hash = await provider.send('eth_sendTransaction', [{ from: legacy.owner, to, data: new Interface([signature]).encodeFunctionData(method, args), gas: '0x180000' }]);
      assert.equal((await provider.waitForTransaction(hash)).status, 1);
    }
    await provider.send('anvil_stopImpersonatingAccount', [legacy.owner]);
  }
  for (const name of ['vitalik.eth', 'wrapped.eth']) {
    const before = await service.inspect({ name });
    assert.equal(before.ensVersion, 1);
    await finish(await service.prepare({ name, intent: 'renew' }, context));
    const after = await service.inspect({ name });
    assert.equal(after.owner, before.owner);
    assert.equal(after.manager, before.manager);
    assert.equal(BigInt(after.expiry), BigInt(before.expiry) + 31536000n);
    assert.deepEqual(after.records, before.records);
    if (before.wrapped) assert.equal(BigInt(after.wrapperExpiry), BigInt(after.expiry) + LEGACY_WRAPPER_GRACE);
    console.log(JSON.stringify({ legacyName: name, wrapped: before.wrapped, renewal: 'verified', ownerManagerRecords: 'preserved' }));
  }
  service.close();
  assert.equal(approvals, sent);
  console.log(JSON.stringify({ passed: true, approvals, sent, steps: [...new Set(titles.map(title => title.replace(/ (of |for )?\S+\.(eth|wei|gwei)$/, '')))] }));
} finally {
  provider.destroy();
}
