open Ast

(** [parse s] parses [s] into an AST. *)
let parse (s : string) : expr =
  let lexbuf = Lexing.from_string s in
  let ast = Parser.prog Lexer.read lexbuf in
  ast

(** [typ] represents the type of an expression. *)
type typ =
  | TInt
  | TBool
  | TVector2 of typ * typ
  | TTagged of typ * tag

(** The error message produced if a variable is unbound. *)
let unbound_var_err = "Unbound variable"

(** The error message produced if binary operators and their
    operands do not have the correct types. *)
let bop_err = "Operator and operand type mismatch"

(** The error message produced if the [then] and [else] branches
    of an [if] do not have the same type. *)
let if_branch_err = "Branches of if must have same type"

(** The error message produced if the guard
    of an [if] does not have type [bool]. *)
let if_guard_err = "Guard of if must have type bool"

let tag_mismatch = "Tags of same space must have matching values"

(** A [Context] is a mapping from variable names to
    types, aka a symbol table, aka a typing environment. *)
module type Context = sig

  (** [t] is the type of a context. *)
  type t

  (** [empty] is the empty context. *)
  val empty : t

  (** [lookup ctx x] gets the binding of [x] in [ctx]. 
      Raises: [Failure unbound_var_err] if [x] is
      not bound in [ctx]. *) 
  val lookup : t -> string -> typ

  (** [extend ctx x ty] is [ctx] extended with a binding
      of [x] to [ty]. *)
  val extend : t -> string -> typ -> t
end

(** The [Context] module implements the [Context] signature 
    with an association list. *)
module Context : Context = struct
  type t = (string * typ) list

  let empty = []

  let lookup ctx x =
    try List.assoc x ctx
    with Not_found -> failwith unbound_var_err

  let extend ctx x ty =
    (x, ty) :: ctx
end

open Context


let tagsAreCompatible tag1 tag2 = 
  match (tag1, tag2) with
  | (Tag(s1, v1), Tag(s2, v2))
    -> if ((s1 = s2) && (v1 <> v2)) then false else true



(** [typeof ctx e] is the type of [e] in context [ctx]. 
    Raises: [Failure] if [e] is not well typed in [ctx]. *)
let rec typeof ctx = function
  | Int _ -> TInt
  | Bool _ -> TBool
  | Vector2 (e1, e2) -> (
      match (e1, e2) with
      (* Two tags in a binop must be compatible. If so, pass on the first tag *)
      |(TaggedExpr(te1, tag1), TaggedExpr(te2, tag2)) 
        ->if (tagsAreCompatible tag1 tag2) 
            (*The first tag is inherited. If tag lists were implemented the tags would be combined here*)
            then TTagged(TVector2(typeof ctx e1, typeof ctx e2), tag1)
            else failwith tag_mismatch
      |(TaggedExpr(te1, tag1), _) 
        -> TTagged(TVector2(typeof ctx e1, typeof ctx e2), tag1)
      |(_, TaggedExpr(te2, tag2)) 
        -> TTagged(TVector2(typeof ctx e1, typeof ctx e2), tag2)
      |_ -> TVector2(typeof ctx e1, typeof ctx e2)
  )
  | Var x -> lookup ctx x
  (* The type of a tagged expression is TTagged with the original tag and typ Type *)
  | TaggedExpr (e, t) -> TTagged(typeof ctx e, t) 
  | Let (x, e1, e2) -> typeof_let ctx x e1 e2
  | Binop (bop, e1, e2) -> (
      match (e1, e2) with
      (* Two tags in a binop must be compatible. If so, pass on the first tag *)
      |(TaggedExpr(te1, tag1), TaggedExpr(te2, tag2)) 
        ->if (tagsAreCompatible tag1 tag2) 
            (*The first tag is inherited. If tag lists were implemented the tags would be combined here*)
            then TTagged(typeof_bop ctx bop te1 te2, tag1)
            else failwith tag_mismatch
      |(TaggedExpr(te1, tag1), _) 
        -> TTagged(typeof_bop ctx bop te1 e2, tag1)
      |(_, TaggedExpr(te2, tag2)) 
        -> TTagged(typeof_bop ctx bop e1 te2, tag2)
      |_ -> typeof_bop ctx bop e1 e2
  )
  | If (e1, e2, e3) -> typeof_if ctx e1 e2 e3
  
(** Helper function for [typeof]. *)
and typeof_let ctx x e1 e2 = 
  let t1 = typeof ctx e1 in
  let ctx' = extend ctx x t1 in
  typeof ctx' e2

(** Helper function for [typeof]. *)
and typeof_bop ctx bop e1 e2 =
  let t1, t2 = typeof ctx e1, typeof ctx e2 in
  match bop, t1, t2 with
  | Add, TInt, TInt
  | Mult, TInt, TInt -> TInt
  | Leq, TInt, TInt -> TBool
  | Add, TVector2(_,_), TVector2(_,_) ->(
    match bop, e1, e2 with
    | Add, Vector2 (e11,e12), Vector2(e21,e22) -> TVector2((typeof_bop ctx bop e11 e12),(typeof_bop ctx bop e21 e22))
    |_ -> failwith bop_err
    )
  | _ -> failwith bop_err

(** Helper function for [typeof]. *)
and typeof_if ctx e1 e2 e3 =
  if typeof ctx e1 = TBool 
  then begin
    let t2 = typeof ctx e2 in
    if t2 = typeof ctx e3 then t2
    else failwith if_branch_err
  end
  else failwith if_guard_err



(** [typecheck e] checks whether [e] is well typed in
    the empty context. Raises: [Failure] if not. *)
let typecheck e =
  typeof empty e

(** [is_value e] is whether [e] is a value. *)
let is_value : expr -> bool = function
  | Int _ | Bool _ | Vector2 _ -> true
  | _ -> false
  (* | Var _ | Let _ | Binop _ | If _ | TaggedExpr _ -> false *)

(** [is_value e] is whether [e] is a int. *)
let is_int : expr -> bool = function
| Int _ -> true
| _ -> false
(* | Var _ | Let _ | Binop _ | If _ | Bool _ | Vector2 _ -> false *)

(** [subst e v x] is [e] with [v] substituted for [x], that
    is, [e{v/x}]. *)
let rec subst e v x = match e with
  | Var y -> if x = y then v else e
  | Bool _ -> e
  | Int _ -> e
  | Binop (bop, e1, e2) -> Binop (bop, subst e1 v x, subst e2 v x)
  | Let (y, e1, e2) ->
    let e1' = subst e1 v x in
    if x = y
    then Let (y, e1', e2)
    else Let (y, e1', subst e2 v x)
  | If (e1, e2, e3) -> 
    If (subst e1 v x, subst e2 v x, subst e3 v x)
  | Vector2 (e1, e2) -> Vector2(subst e1 v x, subst e2 v x)
  | TaggedExpr (e1, t) -> TaggedExpr(subst e1 v x, t)

(** [step] is the [-->] relation, that is, a single step of 
    evaluation. *)
let rec step : expr -> expr = function
  | Int _ | Bool _ -> failwith "Does not step"
  | Var _ -> failwith unbound_var_err
  | Vector2 (e1, e2) when is_value e1 && is_value e2 ->
      failwith "Does not step"
  | Vector2 (e1, e2) when is_value e2 -> 
      Vector2 (step e1, e2)
  | Vector2 (e1, e2) when is_value e1 -> 
      Vector2 (e1, step e2)
  | Vector2 (e1, e2) ->  
      Vector2 (step e1, step e2)
  | Binop (bop, e1, e2) when is_value e1 && is_value e2 -> 
      step_bop bop e1 e2
  | Binop (bop, e1, e2) when is_value e1 ->
      Binop (bop, e1, step e2)
  | Binop (bop, e1, e2) -> Binop (bop, step e1, e2)
  | Let (x, e1, e2) when is_value e1 -> subst e2 e1 x
  | Let (x, e1, e2) -> Let (x, step e1, e2)
  | If (Bool true, e2, _) -> e2
  | If (Bool false, _, e3) -> e3
  | If (Int _, _, _) -> failwith if_guard_err
  | If (e1, e2, e3) -> If (step e1, e2, e3)
  | TaggedExpr (e1, t) -> TaggedExpr(step e1, t)

(** [step_bop bop v1 v2] implements the primitive operation
    [v1 bop v2].  Requires: [v1] and [v2] are both values. *)
and step_bop bop e1 e2 = match bop, e1, e2 with
  | Add, Int a, Int b -> Int (a + b)
  | Mult, Int a, Int b -> Int (a * b)
  | Leq, Int a, Int b -> Bool (a <= b)
  | _ -> failwith bop_err

(** [eval_small e] is the [e -->* v] relation.  That is,
    keep applying [step] until a value is produced.  *)
let rec eval_small (e : expr) : expr = 
  if is_value e then e
  else e |> step |> eval_small

(** [interp_small s] interprets [s] by parsing, type-checking,
    and evaluating it with the small-step model. *)
let interp_small (s : string) : expr =
  let e = parse s in
  ignore(typecheck e);
  eval_small e

(** [eval_big e] is the [e ==> v] relation. *)
let rec eval_big (e : expr) : expr = match e with
  | Int _ | Bool _ -> e
  | Vector2(e1, e2) -> Vector2(eval_big e1, eval_big e2)
  | Var _ -> failwith unbound_var_err
  | Binop (bop, e1, e2) -> eval_bop bop e1 e2
  | Let (x, e1, e2) -> subst e2 (eval_big e1) x |> eval_big
  | If (e1, e2, e3) -> eval_if e1 e2 e3
  | TaggedExpr (e1, t) -> TaggedExpr(eval_big e1, t)

(** [eval_bop bop e1 e2] is the [e] such that [e1 bop e2 ==> e]. *)
and eval_bop bop e1 e2 = match bop, eval_big e1, eval_big e2 with
  | Add, Int a, Int b -> Int (a + b)
  | Mult, Int a, Int b -> Int (a * b)
  | Leq, Int a, Int b -> Bool (a <= b)
  | Add, Vector2 (v11, v12), Vector2 (v21, v22) -> Vector2 (Binop(Add,v11,v21), Binop(Add,v12,v22))
  | _ -> failwith bop_err

(** [eval_if e1 e2 e3] is the [e] such that [if e1 then e2 else e3 ==> e]. *)
and eval_if e1 e2 e3 = match eval_big e1 with
  | Bool true -> eval_big e2
  | Bool false -> eval_big e3
  | _ -> failwith if_guard_err

(** [interp_big s] interprets [s] by parsing, type-checking,
    and evaluating it with the big-step model. *)
let interp_big (s : string) : expr =
  let e = parse s in
  ignore(typecheck e);
  eval_big e


