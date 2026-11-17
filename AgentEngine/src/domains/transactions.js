// Desktop Freedom's DomainTransactions (src/main/wallet/domain-transactions.js)
// over the iPhone's wallet. DomainService supplies an already encoded typed
// plan; this module never accepts calldata from an Agent tool.
//
// iOS: the app (AgentDomains.swift) estimates gas (+20%, as desktop), quotes
// the fee and reads the balance (`quote`), shows the approval sheet with
// unlock and slide (`approve`), and signs and broadcasts only on `send`, after
// the plan was rechecked and journaled here. Its wallet is the phone's own
// (mnemonic) wallet; there are no Ledger or remote signers.

import { formatEther, getAddress } from 'ethers';
import { DomainError, refuse } from './contracts.js';

const walletName = wallet => String(wallet.name || `Wallet ${wallet.index + 1}`).replace(/[\p{Cc}\p{Cf}]/gu, ' ').slice(0, 80);

export class DomainTransactions {
  constructor(host) {
    this.host = host;
  }
  async account(index) {
    if (index !== undefined && (!Number.isSafeInteger(index) || index < 0)) refuse('Choose a valid Freedom wallet account.', 'DOMAIN_INVALID');
    const wallet = await this.host('account', index === undefined ? {} : { index });
    if (!wallet?.address) refuse(wallet?.message || 'Set up or unlock Freedom’s wallet first.');
    return { index: wallet.index, address: getAddress(wallet.address), type: 'mnemonic', name: walletName(wallet) };
  }
  // Whether an address is one of this phone's own wallets, decided from the
  // wallet list itself, never from anything a model says about the address.
  async ownWallet(address) {
    const result = await this.host('ownWallet', { address });
    return result?.status === 'own' ? { status: 'own', name: walletName(result) } : { status: result?.status === 'other' ? 'other' : 'unknown' };
  }
  async send(plan, context) {
    context.signal?.throwIfAborted();
    const account = await this.account(plan.account.index);
    if (account.address !== plan.account.address) refuse('The selected wallet changed. Prepare a new domain operation.', 'DOMAIN_STALE');
    let quote;
    try {
      quote = await this.host('quote', { operationId: plan.id, from: account.address, to: plan.to, data: plan.data, value: plan.value });
    } catch {
      // The node's error text could echo the calldata (a reveal carries its secret).
      refuse('The maximum network fee could not be determined: the transaction may fail. Inspect the name again before retrying.');
    }
    const maxFee = BigInt(quote.maxFeeWei);
    if (maxFee <= 0n) refuse('The maximum network fee could not be determined.');
    const checkBalance = async () => {
      const balance = BigInt((await this.host('balance', { address: account.address })).balanceWei);
      if (balance < BigInt(plan.value) + maxFee) refuse('This wallet needs more ETH for the domain operation and its maximum network fee.', 'DOMAIN_BALANCE');
    };
    try {
      await checkBalance();
      context.signal?.throwIfAborted();
      const decision = await this.host('approve', {
        quoteId: quote.quoteId, label: plan.label, step: plan.step, account,
        to: plan.to, value: `${formatEther(plan.value)} ETH`, maxFee: `${formatEther(maxFee)} ETH`,
        summary: plan.summary, presentation: plan.presentation, data: plan.data,
      });
      if (decision?.status !== 'approved') throw new DomainError('DOMAIN_DECLINED', 'The domain transaction was not approved.');
      context.signal?.throwIfAborted();
      const current = await this.account(account.index);
      if (current.address !== account.address) refuse('The wallet changed during approval.', 'DOMAIN_STALE');
      await context.revalidate();
      await checkBalance();
      context.signal?.throwIfAborted();
      // Journal durably before signing/broadcast; failure from this point is
      // uncertain until reconciled. No signer failure authorizes a second send.
      await context.beforeSend();
      context.signal?.throwIfAborted();
      const sent = await this.host('send', { quoteId: quote.quoteId });
      if (sent?.notBroadcast) throw new DomainError('DOMAIN_NOT_BROADCAST', 'The wallet did not broadcast this step.');
      return { hash: sent?.hash };
    } finally {
      await this.host('finish', { quoteId: quote.quoteId }).catch(() => {});
    }
  }
}
