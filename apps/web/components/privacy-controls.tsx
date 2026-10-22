'use client';
import React from 'react';
import {AccountExport} from './account-export';
export function PrivacyControls(){return <section><h2>Your data and privacy</h2><AccountExport/><section className="account-deletion"><h3>Account deletion</h3><p>Review what is removed, subscription renewal and the cancellation window before requesting deletion.</p><a href="/account/delete">Review account deletion</a></section></section>;}
