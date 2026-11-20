/* A workstation cashier comes from its signed-in account, never from team order. */
(()=>{
 function person(account){return account?.user_id&&Number(account.person_id)>0?Number(account.person_id):null;}
 function participant(account,context){const id=person(account);return id?(context?.participants||[]).find(p=>Number(p.personId)===id&&p.isActive===true)||null:null;}
 function bound(account,context){const p=participant(account,context);return !!p&&Number(context.personId)===Number(p.personId)&&Number(context.employeeId)===Number(p.employeeId)&&(!context.accountUserId||context.accountUserId===account.user_id);}
 window.IprintCashier={person,participant,bound};
})();
