'use client';
import React,{useState} from 'react';
export function PasswordField({newPassword=false}:{newPassword?:boolean}){const[visible,setVisible]=useState(false);return <div className="password-field"><label>Password<input name="password" type={visible?'text':'password'} autoComplete={newPassword?'new-password':'current-password'} required minLength={newPassword?12:1}/></label><button type="button" className="secondary-button" aria-pressed={visible} onClick={()=>setVisible(v=>!v)}>{visible?'Hide':'Show'} password</button></div>}
